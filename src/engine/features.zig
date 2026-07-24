const std = @import("std");
const build_options = @import("build_options");

pub const native_enabled = build_options.native_opencv;

const cv = if (native_enabled) @cImport({
    @cInclude("opencv_bridge.h");
}) else struct {};

pub const Point = extern struct {
    x: f32,
    y: f32,
};

comptime {
    if (native_enabled and
        (@sizeOf(Point) != @sizeOf(cv.AxiaPoint2f) or
        @alignOf(Point) != @alignOf(cv.AxiaPoint2f)))
    {
        @compileError("AxiaPoint2f ABI differs between Zig and the OpenCV bridge");
    }
}

pub const Options = struct {
    grid_columns: u16 = 8,
    grid_rows: u16 = 6,
    max_per_cell: u16 = 12,
    quality_level: f64 = 0.01,
    min_distance: f64 = 5,
    block_size: u16 = 3,
    border: u16 = 8,
};

pub const Cell = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const DetectionError = error{
    OpenCvDisabled,
    InvalidDimensions,
    InvalidStride,
    PixelBufferTooSmall,
    InvalidOptions,
    OutputTooSmall,
    OpenCvFailure,
    SizeOverflow,
};

pub fn requiredCapacity(options: Options) DetectionError!usize {
    try validateOptions(options);
    const cells = std.math.mul(
        usize,
        @as(usize, options.grid_columns),
        @as(usize, options.grid_rows),
    ) catch return error.SizeOverflow;
    return std.math.mul(
        usize,
        cells,
        @as(usize, options.max_per_cell),
    ) catch return error.SizeOverflow;
}

/// Returns the exact image region assigned to a grid cell.
///
/// Integer boundaries share no pixels and cover the complete image, including
/// dimensions that are not divisible by the number of rows or columns.
pub fn gridCell(
    width: usize,
    height: usize,
    options: Options,
    column: usize,
    row: usize,
) DetectionError!Cell {
    try validateOptions(options);
    if (width == 0 or height == 0 or
        column >= options.grid_columns or row >= options.grid_rows)
    {
        return error.InvalidDimensions;
    }

    const columns = @as(usize, options.grid_columns);
    const rows = @as(usize, options.grid_rows);
    const x0 = column * width / columns;
    const x1 = (column + 1) * width / columns;
    const y0 = row * height / rows;
    const y1 = (row + 1) * height / rows;

    return .{
        .x = x0,
        .y = y0,
        .width = x1 - x0,
        .height = y1 - y0,
    };
}

/// Detects Shi-Tomasi corners independently in each grid cell.
///
/// The caller owns both the grayscale pixels and output storage. No allocation
/// occurs per frame and dense texture in one area cannot consume the budget of
/// the rest of the image.
pub fn detectDistributed(
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    output: []Point,
    options: Options,
) DetectionError![]Point {
    if (!native_enabled) return error.OpenCvDisabled;
    try validateImage(pixels, width, height, stride);

    const capacity = try requiredCapacity(options);
    if (output.len < capacity) return error.OutputTooSmall;
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) {
        return error.InvalidDimensions;
    }

    var total: usize = 0;
    for (0..@as(usize, options.grid_rows)) |row| {
        for (0..@as(usize, options.grid_columns)) |column| {
            const cell = try gridCell(width, height, options, column, row);
            const usable = insetCell(cell, width, height, options.border) orelse continue;
            if (usable.width < options.block_size or usable.height < options.block_size) {
                continue;
            }

            const cell_output = output[total .. total + options.max_per_cell];
            var found: usize = 0;
            const status = cv.axia_cv_shi_tomasi_gray8(
                pixels.ptr + usable.y * stride + usable.x,
                @intCast(usable.width),
                @intCast(usable.height),
                stride,
                &.{
                    .max_corners = options.max_per_cell,
                    .quality_level = options.quality_level,
                    .min_distance = options.min_distance,
                    .block_size = options.block_size,
                },
                @ptrCast(cell_output.ptr),
                cell_output.len,
                &found,
            );
            if (status != cv.AXIA_CV_OK) return mapStatus(status);

            for (cell_output[0..found]) |*point| {
                point.x += @floatFromInt(usable.x);
                point.y += @floatFromInt(usable.y);
            }
            total += found;
        }
    }

    return output[0..total];
}

fn validateOptions(options: Options) DetectionError!void {
    if (options.grid_columns == 0 or
        options.grid_rows == 0 or
        options.max_per_cell == 0 or
        !std.math.isFinite(options.quality_level) or
        options.quality_level <= 0 or
        options.quality_level > 1 or
        !std.math.isFinite(options.min_distance) or
        options.min_distance < 0 or
        options.block_size < 3 or
        options.block_size % 2 == 0)
    {
        return error.InvalidOptions;
    }
}

fn validateImage(
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
) DetectionError!void {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (stride < width) return error.InvalidStride;
    const required = std.math.mul(usize, stride, height) catch
        return error.SizeOverflow;
    if (pixels.len < required) return error.PixelBufferTooSmall;
}

fn insetCell(
    cell: Cell,
    image_width: usize,
    image_height: usize,
    border: u16,
) ?Cell {
    const inset = @as(usize, border);
    const left = if (cell.x == 0) @min(inset, cell.width) else 0;
    const top = if (cell.y == 0) @min(inset, cell.height) else 0;
    const at_right = cell.x + cell.width == image_width;
    const at_bottom = cell.y + cell.height == image_height;
    const right = if (at_right) @min(inset, cell.width - left) else 0;
    const bottom = if (at_bottom) @min(inset, cell.height - top) else 0;
    if (left + right >= cell.width or top + bottom >= cell.height) return null;

    return .{
        .x = cell.x + left,
        .y = cell.y + top,
        .width = cell.width - left - right,
        .height = cell.height - top - bottom,
    };
}

fn mapStatus(status: c_int) DetectionError {
    return switch (status) {
        cv.AXIA_CV_INVALID_ARGUMENT => error.InvalidOptions,
        cv.AXIA_CV_OUTPUT_TOO_SMALL => error.OutputTooSmall,
        else => error.OpenCvFailure,
    };
}
