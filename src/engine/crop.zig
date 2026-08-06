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
    /// Maximum perceptual zoom change in log(zoom) units per second.
    dynamic_zoom_rate_per_second: f64 = 1.0,
    correction_strength_rate_per_second: f64 = 2.0,
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
        .dynamic => {
            try applyDynamic(
                allocator,
                requirements,
                poses,
                options.dynamic_window_seconds,
                output,
            );
            limitDynamicZoomRate(
                poses,
                options.dynamic_zoom_rate_per_second,
                output,
            );
        },
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
    return scaleCorrection(
        correction,
        try safeCorrectionStrength(
            correction,
            width,
            height,
            options,
        ),
    );
}

/// Constrains a sequence without introducing abrupt per-frame changes in
/// stabilization strength. The backward pass anticipates a future limit and
/// the forward pass eases out of it; neither crosses a scene boundary or ever
/// exceeds the safe strength calculated for an individual frame.
pub fn constrainCorrections(
    allocator: std.mem.Allocator,
    corrections: []trajectory.Correction,
    poses: []const trajectory.Pose,
    width: u32,
    height: u32,
    options: Options,
) CropError!void {
    try validateOptions(width, height, options);
    if (corrections.len != poses.len) return error.LengthMismatch;
    if (corrections.len == 0) return;

    const strengths = try allocator.alloc(f64, corrections.len);
    defer allocator.free(strengths);
    for (corrections, poses, strengths, 0..) |correction, pose, *strength, index| {
        try validatePoseOrder(poses, index, pose);
        strength.* = try safeCorrectionStrength(
            correction,
            width,
            height,
            options,
        );
    }

    var index = corrections.len - 1;
    while (index > 0) : (index -= 1) {
        const previous = index - 1;
        if (poses[previous].segment != poses[index].segment) continue;
        const elapsed = poses[index].timestamp_seconds -
            poses[previous].timestamp_seconds;
        strengths[previous] = @min(
            strengths[previous],
            strengths[index] +
                options.correction_strength_rate_per_second * elapsed,
        );
    }
    for (1..corrections.len) |current| {
        const previous = current - 1;
        if (poses[previous].segment != poses[current].segment) continue;
        const elapsed = poses[current].timestamp_seconds -
            poses[previous].timestamp_seconds;
        strengths[current] = @min(
            strengths[current],
            strengths[previous] +
                options.correction_strength_rate_per_second * elapsed,
        );
    }

    for (corrections, strengths) |*correction, strength| {
        correction.* = scaleCorrection(correction.*, strength);
    }
}

fn safeCorrectionStrength(
    correction: trajectory.Correction,
    width: u32,
    height: u32,
    options: Options,
) CropError!f64 {
    if (try isSafe(
        correction,
        options.max_zoom,
        width,
        height,
        options.edge_margin_pixels,
    )) {
        return 1;
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
    return lower;
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

/// Builds the smallest scene-local envelope whose logarithmic zoom cannot
/// change faster than `rate_per_second`. Both passes only raise the planned
/// zoom, so the crop never falls below a frame's safety requirement.
fn limitDynamicZoomRate(
    poses: []const trajectory.Pose,
    rate_per_second: f64,
    output: []Frame,
) void {
    var scene_start: usize = 0;
    while (scene_start < output.len) {
        var scene_end = scene_start + 1;
        while (scene_end < output.len and
            poses[scene_end].segment == poses[scene_start].segment)
        {
            scene_end += 1;
        }

        var index = scene_end - 1;
        while (index > scene_start) {
            const previous = index - 1;
            const elapsed = poses[index].timestamp_seconds -
                poses[previous].timestamp_seconds;
            const anticipated_log_zoom = @log(output[index].zoom) -
                rate_per_second * elapsed;
            output[previous].zoom = @max(
                output[previous].zoom,
                @exp(anticipated_log_zoom),
            );
            index = previous;
        }

        for (scene_start + 1..scene_end) |current| {
            const previous = current - 1;
            const elapsed = poses[current].timestamp_seconds -
                poses[previous].timestamp_seconds;
            const retained_log_zoom = @log(output[previous].zoom) -
                rate_per_second * elapsed;
            output[current].zoom = @max(
                output[current].zoom,
                @exp(retained_log_zoom),
            );
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
        !std.math.isFinite(options.dynamic_zoom_rate_per_second) or
        options.dynamic_zoom_rate_per_second <= 0 or
        !std.math.isFinite(options.correction_strength_rate_per_second) or
        options.correction_strength_rate_per_second <= 0 or
        !std.math.isFinite(options.edge_margin_pixels) or
        options.edge_margin_pixels < 0 or
        options.edge_margin_pixels >= maximum_margin or
        options.search_iterations == 0)
    {
        return error.InvalidOptions;
    }
}

test "dynamic zoom rate is limited without violating requirements" {
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0.0 },
        .{ .timestamp_seconds = 0.1 },
        .{ .timestamp_seconds = 0.2 },
        .{ .timestamp_seconds = 0.3 },
        .{ .timestamp_seconds = 0.4 },
    };
    const original = [_]Frame{
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
        .{ .zoom = 1.5, .required_zoom = 1.5, .limited = false },
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
    };
    var frames = original;
    const rate = 0.8;
    limitDynamicZoomRate(&poses, rate, &frames);

    for (frames, original) |frame, requirement| {
        try std.testing.expect(frame.zoom >= requirement.zoom);
    }
    for (frames[1..], frames[0 .. frames.len - 1], poses[1..], poses[0 .. poses.len - 1]) |
        current,
        previous,
        current_pose,
        previous_pose,
    | {
        const elapsed = current_pose.timestamp_seconds -
            previous_pose.timestamp_seconds;
        try std.testing.expect(
            @abs(@log(current.zoom) - @log(previous.zoom)) <=
                rate * elapsed + 0.000001,
        );
    }
    try std.testing.expect(frames[0].zoom < frames[1].zoom);
    try std.testing.expect(frames[3].zoom > frames[4].zoom);
}

test "dynamic crop plan applies the configured zoom rate" {
    const corrections = [_]trajectory.Correction{
        .{},
        .{},
        .{ .x = 10 },
        .{},
        .{},
    };
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0.0 },
        .{ .timestamp_seconds = 0.1 },
        .{ .timestamp_seconds = 0.2 },
        .{ .timestamp_seconds = 0.3 },
        .{ .timestamp_seconds = 0.4 },
    };
    const rate = 0.8;
    const frames = try plan(
        std.testing.allocator,
        &corrections,
        &poses,
        100,
        100,
        .{
            .max_zoom = 2,
            .dynamic_window_seconds = 0,
            .dynamic_zoom_rate_per_second = rate,
        },
    );
    defer std.testing.allocator.free(frames);

    for (frames, poses, 0..) |frame, pose, index| {
        try std.testing.expect(frame.zoom >= frame.required_zoom);
        if (index == 0) continue;
        const elapsed = pose.timestamp_seconds -
            poses[index - 1].timestamp_seconds;
        try std.testing.expect(
            @abs(@log(frame.zoom) - @log(frames[index - 1].zoom)) <=
                rate * elapsed + 0.000001,
        );
    }
    try std.testing.expect(frames[0].zoom < frames[1].zoom);
    try std.testing.expect(frames[3].zoom > frames[4].zoom);
}

test "dynamic zoom rate limiter does not cross scene cuts" {
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0.0, .segment = 0 },
        .{ .timestamp_seconds = 0.1, .segment = 0 },
        .{ .timestamp_seconds = 0.2, .segment = 1 },
        .{ .timestamp_seconds = 0.3, .segment = 1 },
    };
    var frames = [_]Frame{
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
        .{ .zoom = 1.5, .required_zoom = 1.5, .limited = false },
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
        .{ .zoom = 1, .required_zoom = 1, .limited = false },
    };
    limitDynamicZoomRate(&poses, 0.8, &frames);

    try std.testing.expect(frames[0].zoom > 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1), frames[2].zoom, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), frames[3].zoom, 0.000001);
}

test "dynamic zoom rate must be finite and positive" {
    try std.testing.expectError(error.InvalidOptions, requiredZoom(
        .{},
        100,
        100,
        .{ .dynamic_zoom_rate_per_second = 0 },
    ));
    try std.testing.expectError(error.InvalidOptions, requiredZoom(
        .{},
        100,
        100,
        .{ .dynamic_zoom_rate_per_second = std.math.inf(f64) },
    ));
}

fn validatePoseOrder(
    poses: []const trajectory.Pose,
    index: usize,
    pose: trajectory.Pose,
) CropError!void {
    if (!std.math.isFinite(pose.timestamp_seconds)) {
        return error.InvalidTimestamp;
    }
    if (index == 0) return;

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
