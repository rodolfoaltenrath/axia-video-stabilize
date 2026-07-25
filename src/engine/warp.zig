const std = @import("std");
const build_options = @import("build_options");
const trajectory = @import("trajectory.zig");

pub const native_enabled = build_options.native_opencv;

const cv = if (native_enabled) @cImport({
    @cInclude("opencv_bridge.h");
}) else struct {};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const AffineMatrix = extern struct {
    m00: f64,
    m01: f64,
    m02: f64,
    m10: f64,
    m11: f64,
    m12: f64,

    pub fn identity() AffineMatrix {
        return .{
            .m00 = 1,
            .m01 = 0,
            .m02 = 0,
            .m10 = 0,
            .m11 = 1,
            .m12 = 0,
        };
    }

    pub fn validate(self: AffineMatrix) WarpError!void {
        if (!std.math.isFinite(self.m00) or
            !std.math.isFinite(self.m01) or
            !std.math.isFinite(self.m02) or
            !std.math.isFinite(self.m10) or
            !std.math.isFinite(self.m11) or
            !std.math.isFinite(self.m12) or
            @abs(self.determinant()) < 0.000000001)
        {
            return error.InvalidTransform;
        }
    }

    pub fn determinant(self: AffineMatrix) f64 {
        return self.m00 * self.m11 - self.m01 * self.m10;
    }

    pub fn apply(self: AffineMatrix, point: Point) Point {
        return .{
            .x = self.m00 * point.x + self.m01 * point.y + self.m02,
            .y = self.m10 * point.x + self.m11 * point.y + self.m12,
        };
    }

    pub fn inverseMap(
        self: AffineMatrix,
        point: Point,
    ) WarpError!Point {
        try self.validate();
        const determinant_value = self.determinant();
        const translated_x = point.x - self.m02;
        const translated_y = point.y - self.m12;
        return .{
            .x = (self.m11 * translated_x -
                self.m01 * translated_y) / determinant_value,
            .y = (-self.m10 * translated_x +
                self.m00 * translated_y) / determinant_value,
        };
    }
};

comptime {
    if (native_enabled and
        (@sizeOf(AffineMatrix) != @sizeOf(cv.AxiaAffine2d) or
        @alignOf(AffineMatrix) != @alignOf(cv.AxiaAffine2d)))
    {
        @compileError("AxiaAffine2d ABI differs between Zig and OpenCV");
    }
}

pub const WarpError = error{
    OpenCvDisabled,
    InvalidDimensions,
    InvalidStride,
    PixelBufferTooSmall,
    InvalidZoom,
    InvalidTransform,
    OpenCvFailure,
    SizeOverflow,
};

/// Builds the input-to-output affine transform used by OpenCV. The correction
/// is applied first, followed by an output-centered crop zoom.
pub fn matrixFromCorrection(
    correction: trajectory.Correction,
    zoom: f64,
    width: u32,
    height: u32,
) WarpError!AffineMatrix {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (!std.math.isFinite(zoom) or zoom < 1) return error.InvalidZoom;
    if (!std.math.isFinite(correction.x) or
        !std.math.isFinite(correction.y) or
        !std.math.isFinite(correction.angle) or
        !std.math.isFinite(correction.scale) or
        correction.scale <= 0)
    {
        return error.InvalidTransform;
    }

    const cosine = @cos(correction.angle) * correction.scale;
    const sine = @sin(correction.angle) * correction.scale;
    const center_x = (@as(f64, @floatFromInt(width)) - 1.0) / 2.0;
    const center_y = (@as(f64, @floatFromInt(height)) - 1.0) / 2.0;
    const matrix = AffineMatrix{
        .m00 = zoom * cosine,
        .m01 = -zoom * sine,
        .m02 = zoom * correction.x + (1.0 - zoom) * center_x,
        .m10 = zoom * sine,
        .m11 = zoom * cosine,
        .m12 = zoom * correction.y + (1.0 - zoom) * center_y,
    };
    try matrix.validate();
    return matrix;
}

/// Warps a full-resolution BGRA frame into caller-owned output storage.
pub fn warpBgra(
    source_pixels: []const u8,
    source_stride: usize,
    destination_pixels: []u8,
    destination_stride: usize,
    width: u32,
    height: u32,
    matrix: AffineMatrix,
) WarpError!void {
    if (!native_enabled) return error.OpenCvDisabled;
    try matrix.validate();
    const row_bytes = std.math.mul(
        usize,
        @as(usize, width),
        4,
    ) catch return error.SizeOverflow;
    const rows: usize = height;
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (source_stride < row_bytes or destination_stride < row_bytes) {
        return error.InvalidStride;
    }
    const source_size = std.math.mul(usize, source_stride, rows) catch
        return error.SizeOverflow;
    const destination_size = std.math.mul(
        usize,
        destination_stride,
        rows,
    ) catch return error.SizeOverflow;
    if (source_pixels.len < source_size or
        destination_pixels.len < destination_size)
    {
        return error.PixelBufferTooSmall;
    }

    const status = cv.axia_cv_warp_affine_bgra8(
        source_pixels.ptr,
        source_stride,
        destination_pixels.ptr,
        destination_stride,
        @intCast(width),
        @intCast(height),
        @ptrCast(&matrix),
    );
    if (status != cv.AXIA_CV_OK) {
        return switch (status) {
            cv.AXIA_CV_INVALID_ARGUMENT => error.InvalidTransform,
            else => error.OpenCvFailure,
        };
    }
}
