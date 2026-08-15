const std = @import("std");
const build_options = @import("build_options");
const features = @import("features.zig");
const types = @import("types.zig");

pub const native_enabled = build_options.native_opencv;

const cv = if (native_enabled) @cImport({
    @cInclude("opencv_bridge.h");
}) else struct {};

pub const OpticalFlowOptions = struct {
    window_size: u16 = 21,
    max_pyramid_level: u8 = 3,
    max_iterations: u16 = 30,
    epsilon: f64 = 0.01,
    min_eigen_threshold: f64 = 0.0001,
    max_forward_error: f32 = 40,
    max_forward_backward_error: f32 = 1.5,
};

pub const RansacOptions = struct {
    reprojection_threshold: f64 = 2.5,
    max_iterations: u32 = 2000,
    confidence: f64 = 0.995,
    refine_iterations: u32 = 10,
};

pub const Options = struct {
    features: features.Options = .{},
    /// Multiplier applied to Shi-Tomasi's contrast threshold on a sparse pass.
    feature_retry_quality_factor: f64 = 0.25,
    /// Multiplier applied to the corner spacing on a sparse pass.
    feature_retry_min_distance_factor: f64 = 0.6,
    /// Retry a valid but weak motion hypothesis below this confidence.
    feature_retry_confidence_threshold: f32 = 0.25,
    optical_flow: OpticalFlowOptions = .{},
    /// Added to the odd LK window size only during an adaptive retry.
    optical_flow_retry_window_increment: u16 = 10,
    /// Additional LK pyramid levels used only during an adaptive retry.
    optical_flow_retry_pyramid_levels: u8 = 1,
    ransac: RansacOptions = .{},
    minimum_tracks: u16 = 12,
    maximum_translation_fraction: f64 = 0.35,
    maximum_rotation_radians: f64 = std.math.pi / 6.0,
    minimum_scale: f64 = 0.67,
    maximum_scale: f64 = 1.5,
};

pub const GrayFrame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
};

pub const Estimate = struct {
    transform: types.SimilarityTransform,
    confidence: f32,
    detected_points: u32,
    tracked_points: u32,
    inlier_points: u32,
    residual_px: f32,
    spatial_coverage: f32,
};

const FeatureDetection = struct {
    points: []features.Point,
    relaxed: bool,
};

pub const MotionError = error{
    OpenCvDisabled,
    InvalidOptions,
    InvalidFrame,
    FrameDimensionsMismatch,
    NotEnoughTracks,
    EstimationFailed,
    OpenCvFailure,
    OutputTooSmall,
    SizeOverflow,
} || features.DetectionError || std.mem.Allocator.Error;

/// Reusable motion estimator. All Zig-side storage is allocated once so video
/// length does not affect memory usage and no allocator is touched per frame.
pub const Estimator = struct {
    allocator: std.mem.Allocator,
    options: Options,
    previous_points: []features.Point,
    current_points: []features.Point,
    backward_points: []features.Point,
    forward_errors: []f32,
    status: []u8,
    inlier_mask: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
    ) MotionError!Estimator {
        try validateOptions(options);
        const capacity = try features.requiredCapacity(options.features);

        const previous_points = try allocator.alloc(features.Point, capacity);
        errdefer allocator.free(previous_points);
        const current_points = try allocator.alloc(features.Point, capacity);
        errdefer allocator.free(current_points);
        const backward_points = try allocator.alloc(features.Point, capacity);
        errdefer allocator.free(backward_points);
        const forward_errors = try allocator.alloc(f32, capacity);
        errdefer allocator.free(forward_errors);
        const status = try allocator.alloc(u8, capacity);
        errdefer allocator.free(status);
        const inlier_mask = try allocator.alloc(u8, capacity);
        errdefer allocator.free(inlier_mask);

        return .{
            .allocator = allocator,
            .options = options,
            .previous_points = previous_points,
            .current_points = current_points,
            .backward_points = backward_points,
            .forward_errors = forward_errors,
            .status = status,
            .inlier_mask = inlier_mask,
        };
    }

    pub fn deinit(self: *Estimator) void {
        self.allocator.free(self.inlier_mask);
        self.allocator.free(self.status);
        self.allocator.free(self.forward_errors);
        self.allocator.free(self.backward_points);
        self.allocator.free(self.current_points);
        self.allocator.free(self.previous_points);
        self.* = undefined;
    }

    pub fn estimate(
        self: *Estimator,
        previous: GrayFrame,
        current: GrayFrame,
    ) MotionError!Estimate {
        if (!native_enabled) return error.OpenCvDisabled;
        try validateFrame(previous);
        try validateFrame(current);
        if (previous.width != current.width or
            previous.height != current.height)
        {
            return error.FrameDimensionsMismatch;
        }

        const detection = try self.detectFeatures(previous);
        var detected = detection.points;
        var used_relaxed_detection = detection.relaxed;
        if (detected.len < @as(usize, self.options.minimum_tracks)) {
            return error.NotEnoughTracks;
        }

        var tracked_count = try self.trackFeatures(
            previous,
            current,
            detected,
            self.options.optical_flow,
        );
        // A plentiful detection can still collapse during optical flow after
        // local occlusion or blur. Give weaker persistent texture one chance.
        if (tracked_count < @as(usize, self.options.minimum_tracks) and
            self.adaptiveRetryWouldChange(detection.relaxed))
        {
            detected = try self.detectRelaxedFeatures(previous);
            used_relaxed_detection = true;
            if (detected.len >= @as(usize, self.options.minimum_tracks)) {
                tracked_count = try self.trackFeatures(
                    previous,
                    current,
                    detected,
                    self.retryOpticalFlowOptions(),
                );
            }
        }
        if (tracked_count < @as(usize, self.options.minimum_tracks)) {
            return error.NotEnoughTracks;
        }

        const initial_estimate = self.estimateTracked(
            previous,
            detected,
            tracked_count,
        ) catch |initial_error| {
            if (self.adaptiveRetryWouldChange(used_relaxed_detection)) {
                const retry = self.estimateRelaxed(
                    previous,
                    current,
                ) catch return initial_error;
                if (retry) |value| return value;
            }
            return initial_error;
        };
        if (!self.adaptiveRetryWouldChange(used_relaxed_detection) or
            initial_estimate.confidence >=
            self.options.feature_retry_confidence_threshold)
        {
            return initial_estimate;
        }

        const retry = self.estimateRelaxed(
            previous,
            current,
        ) catch return initial_estimate;
        const retry_estimate = retry orelse return initial_estimate;
        return if (retry_estimate.confidence > initial_estimate.confidence)
            retry_estimate
        else
            initial_estimate;
    }

    fn estimateRelaxed(
        self: *Estimator,
        previous: GrayFrame,
        current: GrayFrame,
    ) MotionError!?Estimate {
        const detected = try self.detectRelaxedFeatures(previous);
        if (detected.len < @as(usize, self.options.minimum_tracks)) {
            return null;
        }
        const tracked_count = try self.trackFeatures(
            previous,
            current,
            detected,
            self.retryOpticalFlowOptions(),
        );
        if (tracked_count < @as(usize, self.options.minimum_tracks)) {
            return null;
        }
        return try self.estimateTracked(previous, detected, tracked_count);
    }

    fn estimateTracked(
        self: *Estimator,
        previous: GrayFrame,
        detected: []const features.Point,
        tracked_count: usize,
    ) MotionError!Estimate {
        var transform: cv.AxiaSimilarityTransform = undefined;
        var inlier_count: usize = 0;
        const estimation_status = cv.axia_cv_estimate_similarity_ransac(
            @ptrCast(self.previous_points.ptr),
            @ptrCast(self.current_points.ptr),
            tracked_count,
            &.{
                .reprojection_threshold = self.options.ransac.reprojection_threshold,
                .max_iterations = self.options.ransac.max_iterations,
                .confidence = self.options.ransac.confidence,
                .refine_iterations = self.options.ransac.refine_iterations,
            },
            &transform,
            self.inlier_mask.ptr,
            self.inlier_mask.len,
            &inlier_count,
        );
        if (estimation_status != cv.AXIA_CV_OK) {
            return mapStatus(
                "estimando o movimento global",
                estimation_status,
            );
        }

        const result_transform = types.SimilarityTransform{
            .x = transform.x,
            .y = transform.y,
            .angle = transform.angle,
            .scale = transform.scale,
        };
        result_transform.validate() catch return error.EstimationFailed;
        if (inlier_count < 3) return error.EstimationFailed;
        if (!transformIsPlausible(
            result_transform,
            previous.width,
            previous.height,
            self.options,
        )) {
            return error.EstimationFailed;
        }

        const residual = self.calculateResidual(
            result_transform,
            tracked_count,
            inlier_count,
        );
        const retention = @as(f64, @floatFromInt(tracked_count)) /
            @as(f64, @floatFromInt(detected.len));
        const inlier_ratio = @as(f64, @floatFromInt(inlier_count)) /
            @as(f64, @floatFromInt(tracked_count));
        const residual_score = @exp(-@as(f64, residual) / 3.0);
        const spatial_coverage = calculateSpatialCoverage(
            self.previous_points[0..tracked_count],
            self.inlier_mask[0..tracked_count],
            previous.width,
            previous.height,
        );
        const confidence: f32 = @floatCast(std.math.clamp(
            inlier_ratio * @sqrt(retention) * residual_score *
                spatial_coverage,
            0.0,
            1.0,
        ));

        return .{
            .transform = result_transform,
            .confidence = confidence,
            .detected_points = @intCast(detected.len),
            .tracked_points = @intCast(tracked_count),
            .inlier_points = @intCast(inlier_count),
            .residual_px = residual,
            .spatial_coverage = @floatCast(spatial_coverage),
        };
    }

    fn trackFeatures(
        self: *Estimator,
        previous: GrayFrame,
        current: GrayFrame,
        detected: []const features.Point,
        optical_flow: OpticalFlowOptions,
    ) MotionError!usize {
        const flow_status = cv.axia_cv_track_lk_forward_backward_gray8(
            previous.pixels.ptr,
            previous.stride,
            current.pixels.ptr,
            current.stride,
            @intCast(previous.width),
            @intCast(previous.height),
            @ptrCast(detected.ptr),
            detected.len,
            &.{
                .window_size = @intCast(optical_flow.window_size),
                .max_pyramid_level = @intCast(
                    optical_flow.max_pyramid_level,
                ),
                .max_iterations = @intCast(
                    optical_flow.max_iterations,
                ),
                .epsilon = optical_flow.epsilon,
                .min_eigen_threshold = optical_flow.min_eigen_threshold,
            },
            @ptrCast(self.current_points.ptr),
            @ptrCast(self.backward_points.ptr),
            self.forward_errors.ptr,
            self.status.ptr,
            self.current_points.len,
        );
        if (flow_status != cv.AXIA_CV_OK) {
            return mapStatus("calculando o fluxo óptico", flow_status);
        }
        return self.filterTracks(
            detected,
            current.width,
            current.height,
        );
    }

    /// A first pass keeps the normal detector conservative. When it finds too
    /// few points to absorb the losses of optical flow, retry in the same
    /// preallocated buffer with lower contrast and spacing thresholds.
    fn detectFeatures(
        self: *Estimator,
        previous: GrayFrame,
    ) MotionError!FeatureDetection {
        const detected = try features.detectDistributed(
            previous.pixels,
            previous.width,
            previous.height,
            previous.stride,
            self.previous_points,
            self.options.features,
        );
        const capacity = self.previous_points.len;
        const desired_margin = @min(
            capacity,
            @as(usize, self.options.minimum_tracks) * 2,
        );
        if (detected.len >= desired_margin or !self.featureRetryEnabled()) {
            return .{ .points = detected, .relaxed = false };
        }

        return .{
            .points = try self.detectRelaxedFeatures(previous),
            .relaxed = true,
        };
    }

    fn detectRelaxedFeatures(
        self: *Estimator,
        previous: GrayFrame,
    ) MotionError![]features.Point {
        var retry_options = self.options.features;
        retry_options.quality_level *=
            self.options.feature_retry_quality_factor;
        retry_options.min_distance *=
            self.options.feature_retry_min_distance_factor;
        return features.detectDistributed(
            previous.pixels,
            previous.width,
            previous.height,
            previous.stride,
            self.previous_points,
            retry_options,
        );
    }

    fn featureRetryEnabled(self: *const Estimator) bool {
        return self.options.feature_retry_quality_factor < 1 or
            self.options.feature_retry_min_distance_factor < 1;
    }

    fn opticalFlowRetryEnabled(self: *const Estimator) bool {
        return self.options.optical_flow_retry_window_increment > 0 or
            self.options.optical_flow_retry_pyramid_levels > 0;
    }

    fn adaptiveRetryWouldChange(
        self: *const Estimator,
        features_already_relaxed: bool,
    ) bool {
        return self.opticalFlowRetryEnabled() or
            (!features_already_relaxed and self.featureRetryEnabled());
    }

    fn retryOpticalFlowOptions(self: *const Estimator) OpticalFlowOptions {
        var options = self.options.optical_flow;
        options.window_size +=
            self.options.optical_flow_retry_window_increment;
        options.max_pyramid_level +=
            self.options.optical_flow_retry_pyramid_levels;
        return options;
    }

    fn filterTracks(
        self: *Estimator,
        detected: []const features.Point,
        image_width: u32,
        image_height: u32,
    ) usize {
        const maximum_fb_error_squared =
            self.options.optical_flow.max_forward_backward_error *
            self.options.optical_flow.max_forward_backward_error;
        const width: f32 = @floatFromInt(image_width);
        const height: f32 = @floatFromInt(image_height);

        var accepted: usize = 0;
        for (detected, 0..) |previous_point, index| {
            const current_point = self.current_points[index];
            const backward_point = self.backward_points[index];
            const dx = backward_point.x - previous_point.x;
            const dy = backward_point.y - previous_point.y;
            const fb_error_squared = dx * dx + dy * dy;
            if (self.status[index] == 0 or
                !isFinitePoint(current_point) or
                !isFinitePoint(backward_point) or
                current_point.x < 0 or current_point.x >= width or
                current_point.y < 0 or current_point.y >= height or
                !std.math.isFinite(self.forward_errors[index]) or
                self.forward_errors[index] >
                self.options.optical_flow.max_forward_error or
                fb_error_squared > maximum_fb_error_squared)
            {
                continue;
            }

            self.previous_points[accepted] = previous_point;
            self.current_points[accepted] = current_point;
            accepted += 1;
        }
        return accepted;
    }

    fn calculateResidual(
        self: *Estimator,
        transform: types.SimilarityTransform,
        tracked_count: usize,
        inlier_count: usize,
    ) f32 {
        const cosine = @cos(transform.angle) * transform.scale;
        const sine = @sin(transform.angle) * transform.scale;
        var sum: f64 = 0;
        for (
            self.previous_points[0..tracked_count],
            self.current_points[0..tracked_count],
            self.inlier_mask[0..tracked_count],
        ) |previous, current, is_inlier| {
            if (is_inlier == 0) continue;
            const previous_x: f64 = @floatCast(previous.x);
            const previous_y: f64 = @floatCast(previous.y);
            const current_x: f64 = @floatCast(current.x);
            const current_y: f64 = @floatCast(current.y);
            const predicted_x = cosine * previous_x - sine * previous_y +
                transform.x;
            const predicted_y = sine * previous_x + cosine * previous_y +
                transform.y;
            const dx = predicted_x - current_x;
            const dy = predicted_y - current_y;
            sum += @sqrt(dx * dx + dy * dy);
        }
        return @floatCast(sum / @as(f64, @floatFromInt(inlier_count)));
    }
};

fn validateOptions(options: Options) MotionError!void {
    const capacity = try features.requiredCapacity(options.features);
    const retry_quality_level = options.features.quality_level *
        options.feature_retry_quality_factor;
    _ = std.math.add(
        u16,
        options.optical_flow.window_size,
        options.optical_flow_retry_window_increment,
    ) catch return error.InvalidOptions;
    _ = std.math.add(
        u8,
        options.optical_flow.max_pyramid_level,
        options.optical_flow_retry_pyramid_levels,
    ) catch return error.InvalidOptions;
    if (options.minimum_tracks < 3 or
        @as(usize, options.minimum_tracks) > capacity or
        !std.math.isFinite(options.feature_retry_quality_factor) or
        options.feature_retry_quality_factor <= 0 or
        options.feature_retry_quality_factor > 1 or
        !std.math.isFinite(options.feature_retry_min_distance_factor) or
        options.feature_retry_min_distance_factor <= 0 or
        options.feature_retry_min_distance_factor > 1 or
        !std.math.isFinite(options.feature_retry_confidence_threshold) or
        options.feature_retry_confidence_threshold < 0 or
        options.feature_retry_confidence_threshold > 1 or
        options.optical_flow_retry_window_increment % 2 != 0 or
        !std.math.isFinite(retry_quality_level) or
        retry_quality_level <= 0 or
        options.optical_flow.window_size < 3 or
        options.optical_flow.window_size % 2 == 0 or
        options.optical_flow.max_iterations == 0 or
        !std.math.isFinite(options.optical_flow.epsilon) or
        options.optical_flow.epsilon <= 0 or
        !std.math.isFinite(options.optical_flow.min_eigen_threshold) or
        options.optical_flow.min_eigen_threshold < 0 or
        !std.math.isFinite(options.optical_flow.max_forward_error) or
        options.optical_flow.max_forward_error < 0 or
        !std.math.isFinite(options.optical_flow.max_forward_backward_error) or
        options.optical_flow.max_forward_backward_error <= 0 or
        !std.math.isFinite(options.ransac.reprojection_threshold) or
        options.ransac.reprojection_threshold <= 0 or
        options.ransac.max_iterations == 0 or
        !std.math.isFinite(options.ransac.confidence) or
        options.ransac.confidence <= 0 or
        options.ransac.confidence >= 1 or
        !std.math.isFinite(options.maximum_translation_fraction) or
        options.maximum_translation_fraction <= 0 or
        !std.math.isFinite(options.maximum_rotation_radians) or
        options.maximum_rotation_radians <= 0 or
        options.maximum_rotation_radians > std.math.pi or
        !std.math.isFinite(options.minimum_scale) or
        options.minimum_scale <= 0 or
        !std.math.isFinite(options.maximum_scale) or
        options.maximum_scale < options.minimum_scale)
    {
        return error.InvalidOptions;
    }
}

fn transformIsPlausible(
    transform: types.SimilarityTransform,
    width: u32,
    height: u32,
    options: Options,
) bool {
    const width_f: f64 = @floatFromInt(width);
    const height_f: f64 = @floatFromInt(height);
    const diagonal = @sqrt(width_f * width_f + height_f * height_f);
    const translation = @sqrt(
        transform.x * transform.x + transform.y * transform.y,
    );
    return translation <= options.maximum_translation_fraction * diagonal and
        @abs(transform.angle) <= options.maximum_rotation_radians and
        transform.scale >= options.minimum_scale and
        transform.scale <= options.maximum_scale;
}

/// Measures how broadly the RANSAC inliers support the global transform. The
/// bounding box rewards coverage of the image while the covariance determinant
/// requires support in two independent directions. A compact foreground object
/// or a long line therefore receives a low score even when its tracks agree.
fn calculateSpatialCoverage(
    points: []const features.Point,
    inlier_mask: []const u8,
    width: u32,
    height: u32,
) f64 {
    if (points.len != inlier_mask.len or points.len == 0 or
        width == 0 or height == 0)
    {
        return 0;
    }

    const usable_width = @as(f64, @floatFromInt(@max(width - 1, 1)));
    const usable_height = @as(f64, @floatFromInt(@max(height - 1, 1)));
    var minimum_x = std.math.inf(f64);
    var minimum_y = std.math.inf(f64);
    var maximum_x = -std.math.inf(f64);
    var maximum_y = -std.math.inf(f64);
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var count: usize = 0;
    for (points, inlier_mask) |point, is_inlier| {
        if (is_inlier == 0 or !isFinitePoint(point)) continue;
        const x = std.math.clamp(
            @as(f64, @floatCast(point.x)) / usable_width,
            0,
            1,
        );
        const y = std.math.clamp(
            @as(f64, @floatCast(point.y)) / usable_height,
            0,
            1,
        );
        minimum_x = @min(minimum_x, x);
        minimum_y = @min(minimum_y, y);
        maximum_x = @max(maximum_x, x);
        maximum_y = @max(maximum_y, y);
        sum_x += x;
        sum_y += y;
        count += 1;
    }
    if (count < 3) return 0;

    const horizontal = std.math.clamp(
        maximum_x - minimum_x,
        0,
        1,
    );
    const vertical = std.math.clamp(
        maximum_y - minimum_y,
        0,
        1,
    );
    const bounding_box_coverage = @sqrt(horizontal * vertical);

    const count_float = @as(f64, @floatFromInt(count));
    const mean_x = sum_x / count_float;
    const mean_y = sum_y / count_float;
    var variance_x: f64 = 0;
    var variance_y: f64 = 0;
    var covariance_xy: f64 = 0;
    for (points, inlier_mask) |point, is_inlier| {
        if (is_inlier == 0 or !isFinitePoint(point)) continue;
        const normalized_x = std.math.clamp(
            @as(f64, @floatCast(point.x)) / usable_width,
            0,
            1,
        );
        const normalized_y = std.math.clamp(
            @as(f64, @floatCast(point.y)) / usable_height,
            0,
            1,
        );
        const dx = normalized_x - mean_x;
        const dy = normalized_y - mean_y;
        variance_x += dx * dx;
        variance_y += dy * dy;
        covariance_xy += dx * dy;
    }
    variance_x /= count_float;
    variance_y /= count_float;
    covariance_xy /= count_float;
    const covariance_determinant = @max(
        0,
        variance_x * variance_y - covariance_xy * covariance_xy,
    );
    // A uniform distribution over the unit frame has variance 1/12 on each
    // axis, hence 12 * sqrt(det) normalizes that useful reference to one.
    const two_dimensional_coverage = std.math.clamp(
        12.0 * @sqrt(covariance_determinant),
        0,
        1,
    );
    return @sqrt(bounding_box_coverage * two_dimensional_coverage);
}

fn validateFrame(frame: GrayFrame) MotionError!void {
    const width: usize = @intCast(frame.width);
    const height: usize = @intCast(frame.height);
    if (width == 0 or height == 0 or frame.stride < width) {
        return error.InvalidFrame;
    }
    const required = std.math.mul(usize, frame.stride, height) catch
        return error.SizeOverflow;
    if (frame.pixels.len < required) return error.InvalidFrame;
}

fn isFinitePoint(point: features.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn mapStatus(operation: []const u8, status: c_int) MotionError {
    return switch (status) {
        cv.AXIA_CV_INVALID_ARGUMENT => error.InvalidOptions,
        cv.AXIA_CV_OUTPUT_TOO_SMALL => error.OutputTooSmall,
        cv.AXIA_CV_ESTIMATION_FAILED => error.EstimationFailed,
        else => blk: {
            logOpenCvError(operation, status);
            break :blk error.OpenCvFailure;
        },
    };
}

fn logOpenCvError(operation: []const u8, status: c_int) void {
    const raw_message = cv.axia_cv_last_error();
    if (raw_message != null and raw_message[0] != 0) {
        std.log.err("OpenCV: {s}: {s} ({d})", .{
            operation,
            std.mem.span(raw_message),
            status,
        });
    } else {
        std.log.err("OpenCV: {s}: código {d}", .{ operation, status });
    }
}

test "spatial coverage rewards inliers spread across the frame" {
    const spread = [_]features.Point{
        .{ .x = 5, .y = 5 },
        .{ .x = 95, .y = 5 },
        .{ .x = 5, .y = 95 },
        .{ .x = 95, .y = 95 },
    };
    const clustered = [_]features.Point{
        .{ .x = 45, .y = 45 },
        .{ .x = 50, .y = 45 },
        .{ .x = 45, .y = 50 },
        .{ .x = 50, .y = 50 },
    };
    const inliers = [_]u8{1} ** 4;

    const spread_score = calculateSpatialCoverage(
        &spread,
        &inliers,
        101,
        101,
    );
    const clustered_score = calculateSpatialCoverage(
        &clustered,
        &inliers,
        101,
        101,
    );
    try std.testing.expect(spread_score > 0.85);
    try std.testing.expect(clustered_score < 0.1);
}

test "spatial coverage rejects inliers aligned across the frame" {
    const diagonal = [_]features.Point{
        .{ .x = 5, .y = 5 },
        .{ .x = 25, .y = 25 },
        .{ .x = 50, .y = 50 },
        .{ .x = 75, .y = 75 },
        .{ .x = 95, .y = 95 },
    };
    const inliers = [_]u8{1} ** diagonal.len;

    const score = calculateSpatialCoverage(
        &diagonal,
        &inliers,
        101,
        101,
    );
    try std.testing.expect(score < 0.05);
}

test "motion plausibility rejects degenerate frame transforms" {
    const options = Options{};
    try std.testing.expect(transformIsPlausible(
        .{ .x = 4, .y = -3, .angle = 0.02, .scale = 1.01 },
        1920,
        1080,
        options,
    ));
    try std.testing.expect(!transformIsPlausible(
        .{ .x = 900 },
        1920,
        1080,
        options,
    ));
    try std.testing.expect(!transformIsPlausible(
        .{ .angle = std.math.pi / 2.0 },
        1920,
        1080,
        options,
    ));
    try std.testing.expect(!transformIsPlausible(
        .{ .scale = 2 },
        1920,
        1080,
        options,
    ));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .maximum_scale = std.math.inf(f64),
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .minimum_scale = 1.1,
        .maximum_scale = 1.0,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .feature_retry_quality_factor = 0,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .feature_retry_min_distance_factor = std.math.nan(f64),
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .feature_retry_confidence_threshold = 1.01,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .optical_flow_retry_window_increment = 1,
    }));
    try std.testing.expectError(error.InvalidOptions, validateOptions(.{
        .optical_flow = .{ .window_size = std.math.maxInt(u16) },
    }));
}
