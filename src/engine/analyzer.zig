const std = @import("std");
const decoder_mod = @import("decoder.zig");
const features = @import("features.zig");
const motion = @import("motion.zig");
const types = @import("types.zig");

pub const native_enabled =
    decoder_mod.native_enabled and features.native_enabled;

pub const Options = struct {
    decoder: decoder_mod.Options = .{ .output_format = .bgra8_analysis },
    motion: motion.Options = .{},
    low_confidence_threshold: f32 = 0.25,
    /// Secondary acceptance path for broad, well-supported global motion.
    supported_motion_minimum_inliers: u32 = 96,
    supported_motion_minimum_inlier_ratio: f32 = 0.5,
    supported_motion_minimum_spatial_coverage: f32 = 0.4,
    supported_motion_maximum_residual_px: f32 = 1.5,
    /// Confidence needed to veto a pixel-only hard cut. This is intentionally
    /// stricter than the threshold used for an uncertain appearance change.
    hard_scene_cut_tracking_confidence: f32 = 0.5,
    /// A drastic histogram change is vetoed only by exceptionally strong,
    /// spatially distributed tracking. This handles flashes and exposure
    /// changes without weakening detection of genuine scene transitions.
    hard_histogram_cut_tracking_confidence: f32 = 0.7,
    hard_scene_cut_histogram_distance: f32 = 0.55,
    uncertain_scene_cut_histogram_distance: f32 = 0.30,
    hard_scene_cut_pixel_difference: f32 = 0.65,
    uncertain_scene_cut_pixel_difference: f32 = 0.30,
    /// Per-frame appearance change ignored by gradual-transition accumulation.
    gradual_scene_cut_noise_floor: f32 = 0.03,
    /// Accumulated weak evidence needed to split a fade or crossfade.
    gradual_scene_cut_accumulated_difference: f32 = 0.30,
    /// Retained evidence per frame while tracking remains unreliable.
    gradual_scene_cut_decay: f32 = 0.95,
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
    previous_gray_pixels: []u8,
    current_gray_pixels: []u8,
    previous_color_pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    color_stride: usize,
    has_previous: bool = false,
    scene_id: u32 = 0,
    gradual_scene_change_score: f32 = 0,

    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) AnalyzerError!NativeAnalyzer {
        try validateOptions(options);

        var decoder_options = options.decoder;
        decoder_options.output_format = .bgra8_analysis;
        var decoder = try decoder_mod.Decoder.open(
            allocator,
            path,
            decoder_options,
        );
        errdefer decoder.deinit();
        var estimator = try motion.Estimator.init(allocator, options.motion);
        errdefer estimator.deinit();

        const width = decoder.info.analysis.width;
        const height = decoder.info.analysis.height;
        const stride: usize = @intCast(width);
        const gray_buffer_size = std.math.mul(
            usize,
            stride,
            @as(usize, height),
        ) catch return error.FrameBufferSizeMismatch;
        const color_stride = std.math.mul(
            usize,
            stride,
            decoder_mod.PixelFormat.bgra8_analysis.bytesPerPixel(),
        ) catch return error.FrameBufferSizeMismatch;
        const color_buffer_size = std.math.mul(
            usize,
            color_stride,
            @as(usize, height),
        ) catch return error.FrameBufferSizeMismatch;
        const previous_gray_pixels = try allocator.alloc(u8, gray_buffer_size);
        errdefer allocator.free(previous_gray_pixels);
        const current_gray_pixels = try allocator.alloc(u8, gray_buffer_size);
        errdefer allocator.free(current_gray_pixels);
        const previous_color_pixels = try allocator.alloc(
            u8,
            color_buffer_size,
        );
        errdefer allocator.free(previous_color_pixels);

        return .{
            .allocator = allocator,
            .decoder = decoder,
            .estimator = estimator,
            .options = options,
            .previous_gray_pixels = previous_gray_pixels,
            .current_gray_pixels = current_gray_pixels,
            .previous_color_pixels = previous_color_pixels,
            .width = width,
            .height = height,
            .stride = stride,
            .color_stride = color_stride,
        };
    }

    pub fn deinit(self: *NativeAnalyzer) void {
        self.allocator.free(self.previous_color_pixels);
        self.allocator.free(self.current_gray_pixels);
        self.allocator.free(self.previous_gray_pixels);
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
        try self.convertFrameToGray(frame);
        if (!self.has_previous) {
            try self.copyFrame(frame);
            self.has_previous = true;
            return types.AnalysisRecord.reference(frame.timing, 0);
        }

        const previous = motion.GrayFrame{
            .pixels = self.previous_gray_pixels,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
        };
        const current = motion.GrayFrame{
            .pixels = self.current_gray_pixels,
            .width = frame.width,
            .height = frame.height,
            .stride = self.stride,
        };
        var difference = frameDifference(previous, current);
        difference.histogram = @max(
            difference.histogram,
            colorHistogramDifference(
                self.previous_color_pixels,
                self.color_stride,
                frame.pixels,
                frame.stride,
                self.width,
                self.height,
            ),
        );
        const estimate_optional: ?motion.Estimate =
            self.estimator.estimate(previous, current) catch |err| switch (err) {
            error.NotEnoughTracks, error.EstimationFailed => null,
            else => return err,
        };

        const immediate_scene_cut = self.isSceneCut(
            difference,
            estimate_optional,
        );
        const scene_cut = if (immediate_scene_cut) blk: {
            self.gradual_scene_change_score = 0;
            break :blk true;
        } else updateGradualSceneChange(
            &self.gradual_scene_change_score,
            difference,
            estimate_optional,
            self.options,
        );

        var record: types.AnalysisRecord = undefined;
        if (scene_cut) {
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
                    .low_confidence = !estimateIsReliable(
                        estimate,
                        self.options,
                    ),
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
            frame.format != .bgra8_analysis or
            frame.stride < self.color_stride or
            frame.pixels.len < frame.stride * height)
        {
            return error.FrameBufferSizeMismatch;
        }
        for (0..height) |row| {
            const gray_start = row * self.stride;
            @memcpy(
                self.previous_gray_pixels[gray_start .. gray_start + width],
                self.current_gray_pixels[gray_start .. gray_start + width],
            );
            const source_start = row * frame.stride;
            const color_start = row * self.color_stride;
            @memcpy(
                self.previous_color_pixels[color_start .. color_start + self.color_stride],
                frame.pixels[source_start .. source_start + self.color_stride],
            );
        }
    }

    fn convertFrameToGray(
        self: *NativeAnalyzer,
        frame: decoder_mod.FrameView,
    ) AnalyzerError!void {
        const width: usize = @intCast(frame.width);
        const height: usize = @intCast(frame.height);
        if (frame.format != .bgra8_analysis or
            frame.width != self.width or frame.height != self.height or
            frame.stride < self.color_stride or
            frame.pixels.len < frame.stride * height)
        {
            return error.FrameBufferSizeMismatch;
        }
        for (0..height) |row| {
            const source = frame.pixels[row * frame.stride .. row * frame.stride + self.color_stride];
            const destination = self.current_gray_pixels[row * self.stride .. row * self.stride + width];
            for (destination, 0..) |*gray, column| {
                const pixel = source[column * 4 ..][0..4];
                const luminance = @as(u32, pixel[2]) * 77 +
                    @as(u32, pixel[1]) * 150 +
                    @as(u32, pixel[0]) * 29 + 128;
                gray.* = @intCast(luminance >> 8);
            }
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
    // change is strong evidence of a cut. Exceptionally reliable global
    // tracking can still prove continuity through a flash, exposure change or
    // fast pan. The higher threshold keeps this veto deliberately conservative.
    if (difference.histogram >= options.hard_scene_cut_histogram_distance) {
        const exceptional_tracking = if (estimate) |value|
            value.confidence >=
                options.hard_histogram_cut_tracking_confidence
        else
            false;
        return !exceptional_tracking;
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

fn estimateIsReliable(estimate: motion.Estimate, options: Options) bool {
    if (estimate.confidence >= options.low_confidence_threshold) return true;
    if (estimate.tracked_points == 0 or
        estimate.inlier_points > estimate.tracked_points)
    {
        return false;
    }
    const inlier_ratio = @as(f64, @floatFromInt(estimate.inlier_points)) /
        @as(f64, @floatFromInt(estimate.tracked_points));
    return estimate.inlier_points >= options.supported_motion_minimum_inliers and
        inlier_ratio >= options.supported_motion_minimum_inlier_ratio and
        estimate.spatial_coverage >=
        options.supported_motion_minimum_spatial_coverage and
        estimate.residual_px <= options.supported_motion_maximum_residual_px;
}

fn validateOptions(options: Options) AnalyzerError!void {
    const hard_histogram_confidence =
        options.hard_histogram_cut_tracking_confidence;
    if (!std.math.isFinite(options.low_confidence_threshold) or
        options.low_confidence_threshold < 0 or
        options.low_confidence_threshold > 1 or
        options.supported_motion_minimum_inliers < 3 or
        !std.math.isFinite(options.supported_motion_minimum_inlier_ratio) or
        options.supported_motion_minimum_inlier_ratio <= 0 or
        options.supported_motion_minimum_inlier_ratio > 1 or
        !std.math.isFinite(
        options.supported_motion_minimum_spatial_coverage,
    ) or
        options.supported_motion_minimum_spatial_coverage <= 0 or
        options.supported_motion_minimum_spatial_coverage > 1 or
        !std.math.isFinite(options.supported_motion_maximum_residual_px) or
        options.supported_motion_maximum_residual_px <= 0 or
        !std.math.isFinite(options.hard_scene_cut_tracking_confidence) or
        options.hard_scene_cut_tracking_confidence <
        options.low_confidence_threshold or
        options.hard_scene_cut_tracking_confidence > 1 or
        !std.math.isFinite(hard_histogram_confidence) or
        hard_histogram_confidence <
        options.hard_scene_cut_tracking_confidence or
        hard_histogram_confidence > 1 or
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
        options.hard_scene_cut_pixel_difference or
        !std.math.isFinite(options.gradual_scene_cut_noise_floor) or
        options.gradual_scene_cut_noise_floor < 0 or
        options.gradual_scene_cut_noise_floor >=
        options.gradual_scene_cut_accumulated_difference or
        !std.math.isFinite(
        options.gradual_scene_cut_accumulated_difference,
    ) or
        options.gradual_scene_cut_accumulated_difference <= 0 or
        options.gradual_scene_cut_accumulated_difference > 1 or
        !std.math.isFinite(options.gradual_scene_cut_decay) or
        options.gradual_scene_cut_decay < 0 or
        options.gradual_scene_cut_decay > 1)
    {
        return error.InvalidOptions;
    }
}

fn updateGradualSceneChange(
    score: *f32,
    difference: FrameDifference,
    estimate: ?motion.Estimate,
    options: Options,
) bool {
    const tracking_is_reliable = if (estimate) |value|
        value.confidence >= options.low_confidence_threshold
    else
        false;
    if (tracking_is_reliable) {
        score.* = 0;
        return false;
    }

    const appearance_change = @max(difference.histogram, difference.pixels);
    const evidence = @max(
        0,
        appearance_change - options.gradual_scene_cut_noise_floor,
    );
    score.* = score.* * options.gradual_scene_cut_decay + evidence;
    if (score.* < options.gradual_scene_cut_accumulated_difference) {
        return false;
    }
    score.* = 0;
    return true;
}

const FrameDifference = struct {
    histogram: f32,
    pixels: f32,
};

/// Compares per-channel color distributions without depending on pixel
/// alignment. Alpha is deliberately ignored.
fn colorHistogramDifference(
    previous: []const u8,
    previous_stride: usize,
    current: []const u8,
    current_stride: usize,
    frame_width: u32,
    frame_height: u32,
) f32 {
    const channel_count = 3;
    const bin_count = 16;
    const width: usize = @intCast(frame_width);
    const height: usize = @intCast(frame_height);
    var previous_histogram = [_]u64{0} ** (channel_count * bin_count);
    var current_histogram = [_]u64{0} ** (channel_count * bin_count);
    for (0..height) |row| {
        const previous_row = previous[row * previous_stride .. row * previous_stride + width * 4];
        const current_row = current[row * current_stride .. row * current_stride + width * 4];
        for (0..width) |column| {
            for (0..channel_count) |channel| {
                const histogram_index = channel * bin_count;
                previous_histogram[
                    histogram_index +
                        previous_row[column * 4 + channel] / (256 / bin_count)
                ] += 1;
                current_histogram[
                    histogram_index +
                        current_row[column * 4 + channel] / (256 / bin_count)
                ] += 1;
            }
        }
    }

    var difference: u64 = 0;
    for (previous_histogram, current_histogram) |left, right| {
        difference += if (left > right) left - right else right - left;
    }
    const sample_count = @as(u64, frame_width) *
        @as(u64, frame_height) * channel_count;
    return @floatCast(
        @as(f64, @floatFromInt(difference)) /
            (2.0 * @as(f64, @floatFromInt(sample_count))),
    );
}

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

test "color histogram detects a cut with unchanged luminance" {
    const previous_color = [_]u8{ 0, 0, 255, 255 } ** 4;
    const current_color = [_]u8{ 0, 131, 0, 255 } ** 4;
    const previous_gray = [_]u8{77} ** 4;
    const current_gray = [_]u8{77} ** 4;
    const gray_difference = frameDifference(
        .{ .pixels = &previous_gray, .width = 2, .height = 2, .stride = 2 },
        .{ .pixels = &current_gray, .width = 2, .height = 2, .stride = 2 },
    );
    const color_difference = colorHistogramDifference(
        &previous_color,
        8,
        &current_color,
        8,
        2,
        2,
    );

    try std.testing.expectApproxEqAbs(
        @as(f32, 0),
        gray_difference.histogram,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0),
        gray_difference.pixels,
        0.000001,
    );
    try std.testing.expect(color_difference > 0.6);
    try std.testing.expect(classifySceneCut(
        .{ .histogram = color_difference, .pixels = 0 },
        null,
        .{},
    ));
}

test "global tracking vetoes a uniform exposure change" {
    if (!motion.native_enabled) return error.SkipZigTest;

    const width = 160;
    const height = 120;
    var previous = [_]u8{20} ** (width * height);
    var current = [_]u8{52} ** (width * height);
    for (0..3) |row| {
        for (0..4) |column| {
            const left = 2 + column * (width - 11) / 3;
            const top = 2 + row * (height - 11) / 2;
            for (0..7) |square_y| {
                @memset(
                    previous[(top + square_y) * width + left .. (top + square_y) * width + left + 7],
                    180,
                );
                @memset(
                    current[(top + square_y) * width + left .. (top + square_y) * width + left + 7],
                    212,
                );
            }
        }
    }

    const previous_frame = motion.GrayFrame{
        .pixels = &previous,
        .width = width,
        .height = height,
        .stride = width,
    };
    const current_frame = motion.GrayFrame{
        .pixels = &current,
        .width = width,
        .height = height,
        .stride = width,
    };
    var estimator = try motion.Estimator.init(std.testing.allocator, .{
        .features = .{
            .grid_columns = 4,
            .grid_rows = 3,
            .max_per_cell = 12,
            .min_distance = 3,
            .border = 0,
        },
        .minimum_tracks = 12,
    });
    defer estimator.deinit();

    const estimate = try estimator.estimate(previous_frame, current_frame);
    const difference = frameDifference(previous_frame, current_frame);
    const options = Options{};
    try std.testing.expect(
        difference.histogram >= options.hard_scene_cut_histogram_distance,
    );
    try std.testing.expect(
        estimate.confidence >=
            options.hard_histogram_cut_tracking_confidence,
    );
    try std.testing.expect(!classifySceneCut(
        difference,
        estimate,
        options,
    ));
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

test "broad motion support rescues an estimate below scalar confidence" {
    const options = Options{};
    var estimate = testMotionEstimate(
        options.low_confidence_threshold - 0.05,
    );
    estimate.detected_points = 240;
    estimate.tracked_points = 200;
    estimate.inlier_points = 120;
    estimate.residual_px = 1;
    estimate.spatial_coverage = 0.45;

    try std.testing.expect(estimateIsReliable(estimate, options));
}

test "secondary reliability rejects localized or weak motion support" {
    const options = Options{};
    var estimate = testMotionEstimate(
        options.low_confidence_threshold - 0.05,
    );
    estimate.detected_points = 240;
    estimate.tracked_points = 200;
    estimate.inlier_points = 120;
    estimate.residual_px = 1;
    estimate.spatial_coverage = 0.25;
    try std.testing.expect(!estimateIsReliable(estimate, options));

    estimate.spatial_coverage = 0.45;
    estimate.inlier_points =
        options.supported_motion_minimum_inliers - 1;
    try std.testing.expect(!estimateIsReliable(estimate, options));

    estimate.inlier_points = 120;
    estimate.residual_px =
        options.supported_motion_maximum_residual_px + 0.01;
    try std.testing.expect(!estimateIsReliable(estimate, options));
}

test "secondary reliability options reject invalid limits" {
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .supported_motion_minimum_inliers = 2,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .supported_motion_minimum_inlier_ratio = 1.01,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .supported_motion_minimum_spatial_coverage = 0,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .supported_motion_maximum_residual_px = std.math.inf(f32),
    }));
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

test "gradual scene changes accumulate while tracking is unreliable" {
    const options = Options{};
    const difference = FrameDifference{ .histogram = 0.08, .pixels = 0.06 };
    var score: f32 = 0;
    for (0..6) |_| {
        try std.testing.expect(!updateGradualSceneChange(
            &score,
            difference,
            null,
            options,
        ));
    }
    try std.testing.expect(updateGradualSceneChange(
        &score,
        difference,
        null,
        options,
    ));
    try std.testing.expectEqual(@as(f32, 0), score);
}

test "reliable tracking clears gradual appearance evidence" {
    const options = Options{};
    var score: f32 = 0.2;
    try std.testing.expect(!updateGradualSceneChange(
        &score,
        .{ .histogram = 0.2, .pixels = 0.2 },
        testMotionEstimate(0.8),
        options,
    ));
    try std.testing.expectEqual(@as(f32, 0), score);
}

test "exceptional tracking vetoes a flash-like hard histogram change" {
    const options = Options{};
    try std.testing.expect(!classifySceneCut(
        .{ .histogram = 0.7, .pixels = 0.1 },
        testMotionEstimate(
            options.hard_histogram_cut_tracking_confidence,
        ),
        options,
    ));
}

test "hard histogram change remains a cut without exceptional tracking" {
    const options = Options{};
    const difference = FrameDifference{ .histogram = 0.7, .pixels = 0.1 };
    try std.testing.expect(classifySceneCut(difference, null, options));
    try std.testing.expect(classifySceneCut(
        difference,
        testMotionEstimate(
            options.hard_histogram_cut_tracking_confidence - 0.01,
        ),
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
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .hard_scene_cut_tracking_confidence = 0.6,
        .hard_histogram_cut_tracking_confidence = 0.5,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .hard_histogram_cut_tracking_confidence = std.math.inf(f32),
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .gradual_scene_cut_noise_floor = 0.3,
        .gradual_scene_cut_accumulated_difference = 0.3,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .gradual_scene_cut_decay = 1.1,
    }));
}
