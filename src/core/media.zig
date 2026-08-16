const std = @import("std");

pub const MediaError = error{
    EmptyPath,
    UnsupportedFormat,
    OutputPathTooLong,
    NoAvailableOutputName,
};

pub const PreviewSize = struct {
    width: u32,
    height: u32,
};

pub const maximum_preview_fps: f64 = 30;

const supported_extensions = [_][]const u8{
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".webm",
    ".m4v",
    ".mts",
    ".m2ts",
};

pub fn isSupported(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for (supported_extensions) |supported| {
        if (std.ascii.eqlIgnoreCase(extension, supported)) return true;
    }
    return false;
}

pub fn deriveOutputPath(buffer: []u8, input_path: []const u8) MediaError![]const u8 {
    if (input_path.len == 0) return error.EmptyPath;
    if (!isSupported(input_path)) return error.UnsupportedFormat;

    const extension = std.fs.path.extension(input_path);
    const stem_path = input_path[0 .. input_path.len - extension.len];
    return std.fmt.bufPrint(buffer, "{s}-stabilized.mp4", .{stem_path}) catch error.OutputPathTooLong;
}

/// Chooses a free name for graphical exports so running the same stabilization
/// again never silently replaces a previous result.
pub fn deriveAvailableOutputPath(
    buffer: []u8,
    input_path: []const u8,
) MediaError![]const u8 {
    if (input_path.len == 0) return error.EmptyPath;
    if (!isSupported(input_path)) return error.UnsupportedFormat;

    const extension = std.fs.path.extension(input_path);
    const stem_path = input_path[0 .. input_path.len - extension.len];
    var ordinal: u32 = 1;
    while (ordinal <= 9999) : (ordinal += 1) {
        const candidate = if (ordinal == 1)
            std.fmt.bufPrint(buffer, "{s}-stabilized.mp4", .{stem_path})
        else
            std.fmt.bufPrint(
                buffer,
                "{s}-stabilized-{d}.mp4",
                .{ stem_path, ordinal },
            );
        const output_path = candidate catch return error.OutputPathTooLong;
        if (!pathExists(output_path)) return output_path;
    }
    return error.NoAvailableOutputName;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}

pub fn fitPreviewSize(
    source_width: u32,
    source_height: u32,
    maximum_width: u32,
    maximum_height: u32,
) PreviewSize {
    if (source_width == 0 or source_height == 0) return .{ .width = 2, .height = 2 };

    const width_scale = @as(f64, @floatFromInt(maximum_width)) /
        @as(f64, @floatFromInt(source_width));
    const height_scale = @as(f64, @floatFromInt(maximum_height)) /
        @as(f64, @floatFromInt(source_height));
    const scale = @min(1.0, @min(width_scale, height_scale));
    return .{
        .width = evenDimension(@intFromFloat(@max(2.0, @round(
            @as(f64, @floatFromInt(source_width)) * scale,
        )))),
        .height = evenDimension(@intFromFloat(@max(2.0, @round(
            @as(f64, @floatFromInt(source_height)) * scale,
        )))),
    };
}

/// Keeps the interactive preview light without changing the source or export
/// frame rate. Invalid metadata falls back to the preview ceiling.
pub fn fitPreviewFrameRate(source_fps: f64) f64 {
    if (!std.math.isFinite(source_fps) or source_fps <= 0) {
        return maximum_preview_fps;
    }
    return @min(source_fps, maximum_preview_fps);
}

fn evenDimension(value: u32) u32 {
    return value - value % 2;
}
