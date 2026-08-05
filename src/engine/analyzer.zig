const std = @import("std");
const decoder_mod = @import("decoder.zig");
const features = @import("features.zig");
const motion = @import("motion.zig");
const types = @import("types.zig");

pub const native_enabled =
    decoder_mod.native_enabled and features.native_enabled;

pub const Options = struct {
    decoder: decoder_mod.Options = .{},
    motion: motion.Options = .{},
    low_confidence_threshold: f32 = 0.25,
    /// Confidence needed to veto a pixel-only hard cut. This is intentionally
    /// stricter than the threshold used for an uncertain appearance change.
    hard_scene_cut_tracking_confidence: f32 = 0.5,
    hard_scene_cut_histogram_distance: f32 = 0.55,
    uncertain_scene_cut_histogram_distance: f32 = 0.30,
    hard_scene_cut_pixel_difference: f32 = 0.65,
    uncertain_scene_cut_pixel_difference: f32 = 0.30,
};

pub const AnalyzerError = error{
    BackendNotEnabled,
    InvalidOptions,
    FrameBufferSizeMismatch,
} || decoder_mod.DecoderError || motion.MotionError ||
    types.ValidationError || std.mem.Allocator.Error;

pub const Analyzer = if (native_enabled) NativeAnalyzer else DisabledAnalyzer;

const DisabledAnalyzer = struct {
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) AnalyzerError!DisabledAnalyzer {
        _ = allocator;
        _ = path;
        _ = options;
        return error.BackendNotEnabled;
    }

    pub fn deinit(self: *DisabledAnalyzer) void {
        self.* = undefined;
    }

    pub fn read(self: *DisabledAnalyzer) AnalyzerError!?types.AnalysisRecord {
        _ = self;
        return error.BackendNotEnabled;
    }
};

const NativeAnalyzer = struct {
    allocator: std.mem.Allocator,
    decoder: decoder_mod.Decoder,
    estimator: motion.Estimator,
    options: Options,
    previous_pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    has_previous: bool = false,
    scene_id: u32 = 0,

    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) AnalyzerError!NativeAnalyzer {
        try validateOptions(options);

        var decoder = try decoder_mod.Decoder.open(
            allocator,
            path,
            options.decoder,
        );
        errdefer decoder.deinit();
        var estimator = try motion.Estimator.init(allocator, options.motion);
        errdefer estimator.deinit();

        const width = decoder.info.analysis.width;
        const height = decoder.info.analysis.height;
        const stride: usize = @intCast(width);
        const buffer_size = std.math.mul(
            usize,
            stride,
            @as(usize, height),
        ) catch return error.FrameBufferSizeMismatch;
        const previous_pixels = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(previous_pixels);

        return .{
            .allocator = allocator,
            .decoder = decoder,
            .estimator = estimator,
            .options = options,
            .previous_pixels = previous_pixels,
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    pub fn deinit(self: *NativeAnalyzer) void {
        self.allocator.free(self.previous_pixels);
        self.estimator.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn videoInfo(self: *const NativeAnalyzer) decoder_mod.VideoInfo {
        return self.decoder.info;
    }

    /// Returns exactly one compact record for every decoded frame.
    pub fn read(
        self: *NativeAnalyzer,
    ) AnalyzerError!?types.AnalysisRecord {
        const frame = try self.decoder.readFrame() orelse return null;
        if (!self.has_previous) {
            try self.copyFrame(frame);
            self.has_previous = true;
            return types.AnalysisRecord.reference(frame.timing, 0);
        }

        const previous = motion.GrayFrame{
            .pixels = self.previous_pixels,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
        };
        const current = motion.GrayFrame{
            .pixels = frame.pixels,
            .width = frame.width,
            .height = frame.height,
            .stride = frame.stride,
        };
        const difference = frameDifference(previous, current);
        const estimate_optional: ?motion.Estimate =
            self.estimator.estimate(previous, current) catch |err| switch (err) {
            error.NotEnoughTracks, error.EstimationFailed => null,
            else => return err,
        };

        var record: types.AnalysisRecord = undefined;
        if (self.isSceneCut(difference, estimate_optional)) {
            self.scene_id += 1;
            record = types.AnalysisRecord.reference(
                frame.timing,
                self.scene_id,
            );
            record.flags.scene_cut = true;
        } else if (estimate_optional) |estimate| {
            record = .{
                .timing = frame.timing,
                .global_motion_from_previous = estimate.transform,
                .confidence = estimate.confidence,
                .detected_points = estimate.detected_points,
                .tracked_points = estimate.tracked_points,
                .inlier_points = estimate.inlier_points,
                .residual_px = estimate.residual_px,
                .spatial_coverage = estimate.spatial_coverage,
                .scene_id = self.scene_id,
                .flags = .{
                    .low_confidence = estimate.confidence <
                        self.options.low_confidence_threshold,
                },
            };
        } else {
            record = .{
                .timing = frame.timing,
                .confidence = 0,
                .scene_id = self.scene_id,
                .flags = .{
                    .low_confidence = true,
                    .fallback = true,
                },
            };
        }

        try self.copyFrame(frame);
        try record.validate();
        return record;
    }

    fn copyFrame(
        self: *NativeAnalyzer,
        frame: decoder_mod.FrameView,
    ) AnalyzerError!void {
        const width: usize = @intCast(frame.width);
        const height: usize = @intCast(frame.height);
        if (frame.width != self.width or frame.height != self.height or
            frame.stride < width or
            frame.pixels.len < frame.stride * height)
        {
            return error.FrameBufferSizeMismatch;
        }
        for (0..height) |row| {
            const source_start = row * frame.stride;
            const destination_start = row * self.stride;
            @memcpy(
                self.previous_pixels[destination_start .. destination_start + width],
                frame.pixels[source_start .. source_start + width],
            );
        }
    }

    fn isSceneCut(
        self: *const NativeAnalyzer,
        difference: FrameDifference,
        estimate: ?motion.Estimate,
    ) bool {
        return classifySceneCut(difference, estimate, self.options);
    }
};

fn classifySceneCut(
    difference: FrameDifference,
    estimate: ?motion.Estimate,
    options: Options,
) bool {
    // A histogram comparison does not depend on pixel alignment and a large
    // change is strong evidence of a cut. Pixel-wise difference is different:
    // a fast pan can replace most pixels while optical flow still proves that
    // both frames belong to the same continuous shot.
    if (difference.histogram >= options.hard_scene_cut_histogram_distance) {
        return true;
    }
    const appearance_changed =
        difference.histogram >=
        options.uncertain_scene_cut_histogram_distance or
        difference.pixels >= options.uncertain_scene_cut_pixel_difference;
    if (!appearance_changed) return false;

    const required_tracking_confidence = if (difference.pixels >=
        options.hard_scene_cut_pixel_difference)
        options.hard_scene_cut_tracking_confidence
    else
        options.low_confidence_threshold;
    const reliable_tracking = if (estimate) |value|
        value.confidence >= required_tracking_confidence
    else
        false;
    return !reliable_tracking;
}

fn validateOptions(options: Options) AnalyzerError!void {
    if (options.decoder.output_format != .gray8 or
        !std.math.isFinite(options.low_confidence_threshold) or
        options.low_confidence_threshold < 0 or
        options.low_confidence_threshold > 1 or
        !std.math.isFinite(options.hard_scene_cut_tracking_confidence) or
        options.hard_scene_cut_tracking_confidence <
        options.low_confidence_threshold or
        options.hard_scene_cut_tracking_confidence > 1 or
        !std.math.isFinite(options.hard_scene_cut_histogram_distance) or
        options.hard_scene_cut_histogram_distance <= 0 or
        options.hard_scene_cut_histogram_distance > 1 or
        !std.math.isFinite(options.uncertain_scene_cut_histogram_distance) or
        options.uncertain_scene_cut_histogram_distance <= 0 or
        options.uncertain_scene_cut_histogram_distance >
        options.hard_scene_cut_histogram_distance or
        !std.math.isFinite(options.hard_scene_cut_pixel_difference) or
        options.hard_scene_cut_pixel_difference <= 0 or
        options.hard_scene_cut_pixel_difference > 1 or
        !std.math.isFinite(options.uncertain_scene_cut_pixel_difference) or
        options.uncertain_scene_cut_pixel_difference <= 0 or
        options.uncertain_scene_cut_pixel_difference >
        options.hard_scene_cut_pixel_difference)
    {
        return error.InvalidOptions;
    }
}

const FrameDifference = struct {
    histogram: f32,
    pixels: f32,
};

fn frameDifference(
    previous: motion.GrayFrame,
    current: motion.GrayFrame,
) FrameDifference {
    const bin_count = 32;
    const width: usize = @intCast(previous.width);
    var previous_histogram = [_]u64{0} ** bin_count;
    var current_histogram = [_]u64{0} ** bin_count;
    var pixel_difference: u64 = 0;
    for (0..@as(usize, previous.height)) |row| {
        const previous_start = row * previous.stride;
        const current_start = row * current.stride;
        for (
            previous.pixels[previous_start .. previous_start + width],
            current.pixels[current_start .. current_start + width],
        ) |previous_pixel, current_pixel| {
            previous_histogram[previous_pixel / (256 / bin_count)] += 1;
            current_histogram[current_pixel / (256 / bin_count)] += 1;
            pixel_difference += if (previous_pixel > current_pixel)
                previous_pixel - current_pixel
            else
                current_pixel - previous_pixel;
        }
    }

    var difference: u64 = 0;
    for (previous_histogram, current_histogram) |left, right| {
        difference += if (left > right) left - right else right - left;
    }
    const pixel_count =
        @as(u64, previous.width) * @as(u64, previous.height);
    const pixel_count_float = @as(f64, @floatFromInt(pixel_count));
    return .{
        .histogram = @floatCast(
            @as(f64, @floatFromInt(difference)) /
                (2.0 * pixel_count_float),
        ),
        .pixels = @floatCast(
            @as(f64, @floatFromInt(pixel_difference)) /
                (255.0 * pixel_count_float),
        ),
    };
}

test "pixel difference detects a cut with an unchanged histogram" {
    const previous = [_]u8{ 0, 255, 0, 255 };
    const current = [_]u8{ 255, 0, 255, 0 };
    const difference = frameDifference(
        .{ .pixels = &previous, .width = 2, .height = 2, .stride = 2 },
        .{ .pixels = &current, .width = 2, .height = 2, .stride = 2 },
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0),
        difference.histogram,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1),
        difference.pixels,
        0.000001,
    );
}

fn testMotionEstimate(confidence: f32) motion.Estimate {
    return .{
        .transform = .{ .x = 18, .y = -4 },
        .confidence = confidence,
        .detected_points = 80,
        .tracked_points = 72,
        .inlier_points = 68,
        .residual_px = 0.4,
        .spatial_coverage = 0.8,
    };
}

test "reliable global motion prevents a false pixel-only scene cut" {
    const options = Options{};
    try std.testing.expect(!classifySceneCut(
        .{ .histogram = 0.08, .pixels = 0.82 },
        testMotionEstimate(0.8),
        options,
    ));
}

test "pixel-only appearance change remains a cut without reliable tracking" {
    const options = Options{};
    const difference = FrameDifference{ .histogram = 0.08, .pixels = 0.82 };
    try std.testing.expect(classifySceneCut(difference, null, options));
    try std.testing.expect(classifySceneCut(
        difference,
        testMotionEstimate(options.hard_scene_cut_tracking_confidence - 0.01),
        options,
    ));
}

test "uncertain appearance change accepts moderately reliable tracking" {
    const options = Options{};
    try std.testing.expect(!classifySceneCut(
        .{ .histogram = 0.08, .pixels = 0.35 },
        testMotionEstimate(0.4),
        options,
    ));
}

test "hard histogram change remains a cut despite reliable tracking" {
    const options = Options{};
    try std.testing.expect(classifySceneCut(
        .{ .histogram = 0.7, .pixels = 0.1 },
        testMotionEstimate(0.9),
        options,
    ));
}

test "hard scene-cut tracking confidence cannot be lower than the baseline" {
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .low_confidence_threshold = 0.4,
        .hard_scene_cut_tracking_confidence = 0.3,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .hard_scene_cut_tracking_confidence = std.math.inf(f32),
    }));
}
