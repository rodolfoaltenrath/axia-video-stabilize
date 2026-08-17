const std = @import("std");
const analyzer_mod = @import("analyzer.zig");
const crop = @import("crop.zig");
const decoder = @import("decoder.zig");
const trajectory = @import("trajectory.zig");
const types = @import("types.zig");
const warp = @import("warp.zig");

pub const native_enabled = analyzer_mod.native_enabled;

pub const Stage = enum {
    analyzing,
    smoothing,
};

pub const Progress = struct {
    stage: Stage = .analyzing,
    decoded_frames: u64,
    estimated_frames: ?u64,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_progress: ?*const fn (?*anyopaque, Progress) void = null,
    should_cancel: ?*const fn (?*anyopaque) bool = null,

    fn report(self: Observer, progress: Progress) void {
        if (self.on_progress) |callback| callback(self.context, progress);
    }

    fn isCancelled(self: Observer) bool {
        if (self.should_cancel) |callback| return callback(self.context);
        return false;
    }
};

pub const Options = struct {
    analyzer: analyzer_mod.Options = .{},
    trajectory_integration: trajectory.IntegrationOptions = .{},
    smoothing_radius_seconds: f64 = 1.0,
    crop: crop.Options = .{},
    observer: Observer = .{},
};

pub const SessionError = error{
    BackendNotEnabled,
    Cancelled,
    InvalidOptions,
    FrameCountOverflow,
    InvalidFrameIndex,
} || analyzer_mod.AnalyzerError || trajectory.TrajectoryError ||
    types.ValidationError || crop.CropError || warp.WarpError ||
    std.mem.Allocator.Error;

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    video_info: decoder.VideoInfo,
    records: []types.AnalysisRecord,
    raw_trajectory: []trajectory.Pose,
    smoothed_trajectory: []trajectory.Pose,
    corrections: []trajectory.Correction,
    crop_frames: []crop.Frame,

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.crop_frames);
        self.allocator.free(self.corrections);
        self.allocator.free(self.smoothed_trajectory);
        self.allocator.free(self.raw_trajectory);
        self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn frameCount(self: *const Analysis) usize {
        return self.records.len;
    }

    pub fn renderMatrix(
        self: *const Analysis,
        frame_index: usize,
    ) SessionError!warp.AffineMatrix {
        if (frame_index >= self.records.len) return error.InvalidFrameIndex;
        return warp.matrixFromCorrection(
            self.corrections[frame_index],
            self.crop_frames[frame_index].zoom,
            self.video_info.source.width,
            self.video_info.source.height,
        );
    }
};

pub const Session = if (native_enabled) NativeSession else DisabledSession;

const DisabledSession = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) SessionError!Analysis {
        _ = allocator;
        _ = path;
        _ = options;
        return error.BackendNotEnabled;
    }
};

const NativeSession = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) SessionError!Analysis {
        if (!std.math.isFinite(options.smoothing_radius_seconds) or
            options.smoothing_radius_seconds < 0)
        {
            return error.InvalidOptions;
        }
        if (options.observer.isCancelled()) return error.Cancelled;

        var analyzer = try analyzer_mod.Analyzer.open(
            allocator,
            path,
            options.analyzer,
        );
        defer analyzer.deinit();
        const initial_video_info = analyzer.videoInfo();

        var records = std.ArrayList(types.AnalysisRecord).init(allocator);
        defer records.deinit();
        if (initial_video_info.estimated_frame_count) |estimated| {
            if (estimated > std.math.maxInt(usize)) {
                return error.FrameCountOverflow;
            }
            try records.ensureTotalCapacity(@intCast(estimated));
        }

        while (try analyzer.read()) |record| {
            if (options.observer.isCancelled()) return error.Cancelled;
            try records.append(record);
            options.observer.report(.{
                .stage = .analyzing,
                .decoded_frames = @intCast(records.items.len),
                .estimated_frames = initial_video_info.estimated_frame_count,
            });
        }
        if (options.observer.isCancelled()) return error.Cancelled;
        // Decoding may discover per-frame color metadata that was absent from
        // the container. Read it back after the complete analysis pass.
        const video_info = analyzer.videoInfo();

        options.observer.report(.{
            .stage = .smoothing,
            .decoded_frames = @intCast(records.items.len),
            .estimated_frames = @intCast(records.items.len),
        });

        const owned_records = try records.toOwnedSlice();
        errdefer allocator.free(owned_records);
        const raw_trajectory = try trajectory.integrateAnalysisWithOptions(
            allocator,
            owned_records,
            options.trajectory_integration,
        );
        errdefer allocator.free(raw_trajectory);
        const analysis_center = trajectory.SmoothingPivot{
            .x = (@as(f64, @floatFromInt(video_info.analysis.width)) - 1.0) /
                2.0,
            .y = (@as(f64, @floatFromInt(video_info.analysis.height)) - 1.0) /
                2.0,
        };
        const smoothed_trajectory = try trajectory.smoothTimedAroundPivot(
            allocator,
            raw_trajectory,
            options.smoothing_radius_seconds,
            analysis_center,
        );
        errdefer allocator.free(smoothed_trajectory);
        const analysis_corrections = try trajectory.buildCorrections(
            allocator,
            raw_trajectory,
            smoothed_trajectory,
        );
        defer allocator.free(analysis_corrections);
        const render_corrections = try scaleCorrections(
            allocator,
            analysis_corrections,
            video_info.analysis,
            video_info.source,
        );
        errdefer allocator.free(render_corrections);
        try crop.constrainCorrections(
            allocator,
            render_corrections,
            smoothed_trajectory,
            video_info.source.width,
            video_info.source.height,
            options.crop,
        );
        const crop_frames = try crop.plan(
            allocator,
            render_corrections,
            smoothed_trajectory,
            video_info.source.width,
            video_info.source.height,
            options.crop,
        );
        errdefer allocator.free(crop_frames);

        return .{
            .allocator = allocator,
            .video_info = video_info,
            .records = owned_records,
            .raw_trajectory = raw_trajectory,
            .smoothed_trajectory = smoothed_trajectory,
            .corrections = render_corrections,
            .crop_frames = crop_frames,
        };
    }
};

fn scaleCorrections(
    allocator: std.mem.Allocator,
    corrections: []const trajectory.Correction,
    analysis_dimensions: decoder.Dimensions,
    source_dimensions: decoder.Dimensions,
) (error{InvalidOptions} || std.mem.Allocator.Error)![]trajectory.Correction {
    if (analysis_dimensions.width == 0 or
        analysis_dimensions.height == 0 or
        source_dimensions.width == 0 or
        source_dimensions.height == 0)
    {
        return error.InvalidOptions;
    }
    const output = try allocator.alloc(trajectory.Correction, corrections.len);
    const scale_x = @as(f64, @floatFromInt(source_dimensions.width)) /
        @as(f64, @floatFromInt(analysis_dimensions.width));
    const scale_y = @as(f64, @floatFromInt(source_dimensions.height)) /
        @as(f64, @floatFromInt(analysis_dimensions.height));
    const analysis_center_x =
        (@as(f64, @floatFromInt(analysis_dimensions.width)) - 1.0) / 2.0;
    const analysis_center_y =
        (@as(f64, @floatFromInt(analysis_dimensions.height)) - 1.0) / 2.0;
    const source_center_x =
        (@as(f64, @floatFromInt(source_dimensions.width)) - 1.0) / 2.0;
    const source_center_y =
        (@as(f64, @floatFromInt(source_dimensions.height)) - 1.0) / 2.0;
    for (corrections, output) |correction, *scaled| {
        scaled.* = correction;
        const cosine = @cos(correction.angle) * correction.scale;
        const sine = @sin(correction.angle) * correction.scale;
        const corrected_center_x = cosine * analysis_center_x -
            sine * analysis_center_y + correction.x;
        const corrected_center_y = sine * analysis_center_x +
            cosine * analysis_center_y + correction.y;
        const center_displacement_x =
            (corrected_center_x - analysis_center_x) * scale_x;
        const center_displacement_y =
            (corrected_center_y - analysis_center_y) * scale_y;
        scaled.x = source_center_x + center_displacement_x -
            (cosine * source_center_x - sine * source_center_y);
        scaled.y = source_center_y + center_displacement_y -
            (sine * source_center_x + cosine * source_center_y);
    }
    return output;
}

test "render corrections scale from analysis to source dimensions" {
    const input = [_]trajectory.Correction{
        .{ .x = 4, .y = -3 },
    };
    const output = try scaleCorrections(
        std.testing.allocator,
        &input,
        .{ .width = 960, .height = 540 },
        .{ .width = 1920, .height = 1080 },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(f64, 8), output[0].x);
    try std.testing.expectEqual(@as(f64, -6), output[0].y);
    try std.testing.expectEqual(input[0].angle, output[0].angle);
    try std.testing.expectEqual(input[0].scale, output[0].scale);
}

test "render correction preserves a centered rotation across resolutions" {
    const analysis = decoder.Dimensions{ .width = 853, .height = 480 };
    const source = decoder.Dimensions{ .width = 1920, .height = 1080 };
    const analysis_center_x =
        (@as(f64, @floatFromInt(analysis.width)) - 1.0) / 2.0;
    const analysis_center_y =
        (@as(f64, @floatFromInt(analysis.height)) - 1.0) / 2.0;
    const angle = 0.18;
    const scale = 1.03;
    const cosine = @cos(angle) * scale;
    const sine = @sin(angle) * scale;
    const input = [_]trajectory.Correction{.{
        .x = analysis_center_x - cosine * analysis_center_x +
            sine * analysis_center_y,
        .y = analysis_center_y - sine * analysis_center_x -
            cosine * analysis_center_y,
        .angle = angle,
        .scale = scale,
    }};

    const output = try scaleCorrections(
        std.testing.allocator,
        &input,
        analysis,
        source,
    );
    defer std.testing.allocator.free(output);
    const matrix = try warp.matrixFromCorrection(
        output[0],
        1,
        source.width,
        source.height,
    );
    const source_center = warp.Point{
        .x = (@as(f64, @floatFromInt(source.width)) - 1.0) / 2.0,
        .y = (@as(f64, @floatFromInt(source.height)) - 1.0) / 2.0,
    };
    const corrected_center = matrix.apply(source_center);
    try std.testing.expectApproxEqAbs(
        source_center.x,
        corrected_center.x,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        source_center.y,
        corrected_center.y,
        0.000001,
    );
}
