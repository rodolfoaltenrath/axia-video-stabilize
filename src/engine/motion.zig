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
    optical_flow: OpticalFlowOptions = .{},
    ransac: RansacOptions = .{},
    minimum_tracks: u16 = 12,
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

        const detected = try features.detectDistributed(
            previous.pixels,
            previous.width,
            previous.height,
            previous.stride,
            self.previous_points,
            self.options.features,
        );
        if (detected.len < @as(usize, self.options.minimum_tracks)) {
            return error.NotEnoughTracks;
        }

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
                .window_size = @intCast(self.options.optical_flow.window_size),
                .max_pyramid_level = @intCast(
                    self.options.optical_flow.max_pyramid_level,
                ),
                .max_iterations = @intCast(
                    self.options.optical_flow.max_iterations,
                ),
                .epsilon = self.options.optical_flow.epsilon,
                .min_eigen_threshold = self.options.optical_flow.min_eigen_threshold,
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

        const tracked_count = self.filterTracks(
            detected,
            current.width,
            current.height,
        );
        if (tracked_count < @as(usize, self.options.minimum_tracks)) {
            return error.NotEnoughTracks;
        }

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
        const confidence: f32 = @floatCast(std.math.clamp(
            inlier_ratio * @sqrt(retention) * residual_score,
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
        };
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
    if (options.minimum_tracks < 3 or
        @as(usize, options.minimum_tracks) > capacity or
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
        options.ransac.confidence >= 1)
    {
        return error.InvalidOptions;
    }
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
