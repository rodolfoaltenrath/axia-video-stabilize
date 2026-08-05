const std = @import("std");
const trajectory = @import("trajectory.zig");
const warp = @import("warp.zig");

pub const Mode = enum {
    static,
    dynamic,
};

pub const Options = struct {
    mode: Mode = .dynamic,
    max_zoom: f64 = 1.5,
    extra_crop_fraction: f64 = 0,
    dynamic_window_seconds: f64 = 0.5,
    edge_margin_pixels: f64 = 0,
    search_iterations: u8 = 40,
};

pub const Frame = struct {
    /// Zoom actually applied after temporal planning.
    zoom: f64,
    /// Minimum zoom required by this frame alone.
    required_zoom: f64,
    /// True when even max_zoom cannot fully cover the source boundary.
    limited: bool,
};

pub const Requirement = struct {
    zoom: f64,
    limited: bool,
};

pub const CropError = error{
    LengthMismatch,
    InvalidDimensions,
    InvalidOptions,
    InvalidTimestamp,
    InvalidSegmentOrder,
} || warp.WarpError || std.mem.Allocator.Error;

/// Calculates a safe crop zoom for every correction. Static mode uses one
/// value per scene; dynamic mode uses a centered temporal maximum so it never
/// dips below the safety requirement of the current frame.
pub fn plan(
    allocator: std.mem.Allocator,
    corrections: []const trajectory.Correction,
    poses: []const trajectory.Pose,
    width: u32,
    height: u32,
    options: Options,
) CropError![]Frame {
    try validateOptions(width, height, options);
    if (corrections.len != poses.len) return error.LengthMismatch;

    const output = try allocator.alloc(Frame, corrections.len);
    errdefer allocator.free(output);
    if (corrections.len == 0) return output;

    const requirements = try allocator.alloc(Requirement, corrections.len);
    defer allocator.free(requirements);
    for (corrections, poses, requirements, 0..) |correction, pose, *item, index| {
        if (!std.math.isFinite(pose.timestamp_seconds)) {
            return error.InvalidTimestamp;
        }
        if (index > 0) {
            const previous = poses[index - 1];
            if (pose.segment < previous.segment) {
                return error.InvalidSegmentOrder;
            }
            if (pose.segment == previous.segment and
                pose.timestamp_seconds < previous.timestamp_seconds)
            {
                return error.InvalidTimestamp;
            }
        }
        item.* = try requiredZoom(
            correction,
            width,
            height,
            options,
        );
        output[index] = .{
            .zoom = item.zoom,
            .required_zoom = item.zoom,
            .limited = item.limited,
        };
    }

    switch (options.mode) {
        .static => applyStatic(requirements, poses, output),
        .dynamic => try applyDynamic(
            allocator,
            requirements,
            poses,
            options.dynamic_window_seconds,
            output,
        ),
    }

    for (output) |*frame| {
        frame.zoom = @min(
            options.max_zoom,
            frame.zoom * (1.0 + options.extra_crop_fraction),
        );
    }
    return output;
}

pub fn requiredZoom(
    correction: trajectory.Correction,
    width: u32,
    height: u32,
    options: Options,
) CropError!Requirement {
    try validateOptions(width, height, options);
    if (try isSafe(
        correction,
        1,
        width,
        height,
        options.edge_margin_pixels,
    )) {
        return .{ .zoom = 1, .limited = false };
    }
    if (!try isSafe(
        correction,
        options.max_zoom,
        width,
        height,
        options.edge_margin_pixels,
    )) {
        return .{ .zoom = options.max_zoom, .limited = true };
    }

    var lower: f64 = 1;
    var upper = options.max_zoom;
    for (0..options.search_iterations) |_| {
        const candidate = (lower + upper) / 2.0;
        if (try isSafe(
            correction,
            candidate,
            width,
            height,
            options.edge_margin_pixels,
        )) {
            upper = candidate;
        } else {
            lower = candidate;
        }
    }
    return .{ .zoom = upper, .limited = false };
}

/// Reduces a correction only when the configured maximum zoom cannot keep the
/// complete output frame inside the source image. Translation and rotation are
/// interpolated linearly; scale is interpolated in log space.
pub fn constrainCorrection(
    correction: trajectory.Correction,
    width: u32,
    height: u32,
    options: Options,
) CropError!trajectory.Correction {
    try validateOptions(width, height, options);
    if (try isSafe(
        correction,
        options.max_zoom,
        width,
        height,
        options.edge_margin_pixels,
    )) {
        return correction;
    }

    var lower: f64 = 0;
    var upper: f64 = 1;
    for (0..options.search_iterations) |_| {
        const candidate = (lower + upper) / 2.0;
        const adjusted = scaleCorrection(correction, candidate);
        if (try isSafe(
            adjusted,
            options.max_zoom,
            width,
            height,
            options.edge_margin_pixels,
        )) {
            lower = candidate;
        } else {
            upper = candidate;
        }
    }
    return scaleCorrection(correction, lower);
}

fn scaleCorrection(
    correction: trajectory.Correction,
    amount: f64,
) trajectory.Correction {
    return .{
        .x = correction.x * amount,
        .y = correction.y * amount,
        .angle = correction.angle * amount,
        .scale = @exp(@log(correction.scale) * amount),
    };
}

fn isSafe(
    correction: trajectory.Correction,
    zoom: f64,
    width: u32,
    height: u32,
    margin: f64,
) CropError!bool {
    const matrix = try warp.matrixFromCorrection(
        correction,
        zoom,
        width,
        height,
    );
    const maximum_x = @as(f64, @floatFromInt(width)) - 1.0;
    const maximum_y = @as(f64, @floatFromInt(height)) - 1.0;
    const corners = [_]warp.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = maximum_x, .y = 0 },
        .{ .x = maximum_x, .y = maximum_y },
        .{ .x = 0, .y = maximum_y },
    };
    for (corners) |corner| {
        const source = try matrix.inverseMap(corner);
        if (source.x < margin or source.x > maximum_x - margin or
            source.y < margin or source.y > maximum_y - margin)
        {
            return false;
        }
    }
    return true;
}

fn applyStatic(
    requirements: []const Requirement,
    poses: []const trajectory.Pose,
    output: []Frame,
) void {
    var scene_start: usize = 0;
    while (scene_start < poses.len) {
        var scene_end = scene_start + 1;
        var scene_zoom = requirements[scene_start].zoom;
        while (scene_end < poses.len and
            poses[scene_end].segment == poses[scene_start].segment)
        {
            scene_zoom = @max(scene_zoom, requirements[scene_end].zoom);
            scene_end += 1;
        }
        for (output[scene_start..scene_end]) |*frame| {
            frame.zoom = scene_zoom;
        }
        scene_start = scene_end;
    }
}

fn applyDynamic(
    allocator: std.mem.Allocator,
    requirements: []const Requirement,
    poses: []const trajectory.Pose,
    window_seconds: f64,
    output: []Frame,
) std.mem.Allocator.Error!void {
    const deque = try allocator.alloc(usize, requirements.len);
    defer allocator.free(deque);

    var scene_start: usize = 0;
    while (scene_start < poses.len) {
        var scene_end = scene_start + 1;
        while (scene_end < poses.len and
            poses[scene_end].segment == poses[scene_start].segment)
        {
            scene_end += 1;
        }

        var head: usize = 0;
        var tail: usize = 0;
        var right = scene_start;
        for (scene_start..scene_end) |index| {
            const maximum_time =
                poses[index].timestamp_seconds + window_seconds;
            while (right < scene_end and
                poses[right].timestamp_seconds <= maximum_time)
            {
                while (tail > head and
                    requirements[deque[tail - 1]].zoom <=
                    requirements[right].zoom)
                {
                    tail -= 1;
                }
                deque[tail] = right;
                tail += 1;
                right += 1;
            }

            const minimum_time =
                poses[index].timestamp_seconds - window_seconds;
            while (head < tail and
                poses[deque[head]].timestamp_seconds < minimum_time)
            {
                head += 1;
            }
            output[index].zoom = requirements[deque[head]].zoom;
        }
        scene_start = scene_end;
    }
}

fn validateOptions(
    width: u32,
    height: u32,
    options: Options,
) CropError!void {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const maximum_margin =
        (@as(f64, @floatFromInt(@min(width, height))) - 1.0) / 2.0;
    if (!std.math.isFinite(options.max_zoom) or
        options.max_zoom < 1 or
        !std.math.isFinite(options.extra_crop_fraction) or
        options.extra_crop_fraction < 0 or
        options.extra_crop_fraction > 0.5 or
        !std.math.isFinite(options.dynamic_window_seconds) or
        options.dynamic_window_seconds < 0 or
        !std.math.isFinite(options.edge_margin_pixels) or
        options.edge_margin_pixels < 0 or
        options.edge_margin_pixels >= maximum_margin or
        options.search_iterations == 0)
    {
        return error.InvalidOptions;
    }
}
