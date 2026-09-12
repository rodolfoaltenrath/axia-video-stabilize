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

pub const PreviewProfile = struct {
    maximum_long_edge: u32,
    maximum_short_edge: u32,
    maximum_fps: f64,
    proxy_recommended: bool,
};

pub const PreviewSource = struct {
    width: u32,
    height: u32,
    frames_per_second: f64,
    bit_rate: ?u64 = null,
    hdr: bool = false,
};

pub const maximum_preview_fps: f64 = 30;
pub const standard_preview_profile = PreviewProfile{
    .maximum_long_edge = 960,
    .maximum_short_edge = 540,
    .maximum_fps = maximum_preview_fps,
    .proxy_recommended = false,
};
pub const demanding_preview_profile = PreviewProfile{
    // Expensive portrait sources need the same number of preview pixels as
    // landscape sources. Reducing both through a landscape-only bounding box
    // creates a tiny texture which the monitor then has to magnify.
    .maximum_long_edge = 960,
    .maximum_short_edge = 540,
    .maximum_fps = 24,
    .proxy_recommended = true,
};

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
    return deriveAvailablePathWithSuffix(buffer, input_path, "stabilized");
}

pub fn deriveAvailableEditorOutputPath(
    buffer: []u8,
    input_path: []const u8,
    stabilization_enabled: bool,
) MediaError![]const u8 {
    return deriveAvailablePathWithSuffix(
        buffer,
        input_path,
        if (stabilization_enabled) "stabilized" else "export",
    );
}

fn deriveAvailablePathWithSuffix(
    buffer: []u8,
    input_path: []const u8,
    suffix: []const u8,
) MediaError![]const u8 {
    if (input_path.len == 0) return error.EmptyPath;
    if (!isSupported(input_path)) return error.UnsupportedFormat;

    const extension = std.fs.path.extension(input_path);
    const stem_path = input_path[0 .. input_path.len - extension.len];
    var ordinal: u32 = 1;
    while (ordinal <= 9999) : (ordinal += 1) {
        const candidate = if (ordinal == 1)
            std.fmt.bufPrint(buffer, "{s}-{s}.mp4", .{ stem_path, suffix })
        else
            std.fmt.bufPrint(
                buffer,
                "{s}-{s}-{d}.mp4",
                .{ stem_path, suffix, ordinal },
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

/// Fits a preview into an orientation-aware box. A 16:9 landscape source uses
/// `maximum_long_edge x maximum_short_edge`; its portrait counterpart uses the
/// transposed box. This keeps their effective preview resolution equivalent.
pub fn fitOrientedPreviewSize(
    source_width: u32,
    source_height: u32,
    maximum_long_edge: u32,
    maximum_short_edge: u32,
) PreviewSize {
    return if (source_width >= source_height)
        fitPreviewSize(
            source_width,
            source_height,
            maximum_long_edge,
            maximum_short_edge,
        )
    else
        fitPreviewSize(
            source_width,
            source_height,
            maximum_short_edge,
            maximum_long_edge,
        );
}

/// Keeps the interactive preview light without changing the source or export
/// frame rate. Invalid metadata falls back to the preview ceiling.
pub fn fitPreviewFrameRate(source_fps: f64) f64 {
    if (!std.math.isFinite(source_fps) or source_fps <= 0) {
        return maximum_preview_fps;
    }
    return @min(source_fps, maximum_preview_fps);
}

/// Selects a lighter interactive representation for demanding sources based
/// on pixel rate, encoded bitrate and HDR processing. Analysis and export
/// continue to use the immutable source media.
pub fn previewProfile(source: PreviewSource) PreviewProfile {
    const fps = if (std.math.isFinite(source.frames_per_second) and
        source.frames_per_second > 0)
        source.frames_per_second
    else
        maximum_preview_fps;
    const pixel_rate = @as(f64, @floatFromInt(source.width)) *
        @as(f64, @floatFromInt(source.height)) * fps;
    const full_hd_30_pixel_rate = 1920.0 * 1080.0 * 30.0;
    const high_bit_rate = if (source.bit_rate) |bit_rate|
        bit_rate >= 20_000_000
    else
        false;
    return if (pixel_rate > full_hd_30_pixel_rate or high_bit_rate or source.hdr)
        demanding_preview_profile
    else
        standard_preview_profile;
}

pub fn fitPreviewFrameRateForProfile(
    source_fps: f64,
    profile: PreviewProfile,
) f64 {
    if (!std.math.isFinite(source_fps) or source_fps <= 0) {
        return profile.maximum_fps;
    }
    return @min(source_fps, profile.maximum_fps);
}

fn evenDimension(value: u32) u32 {
    return value - value % 2;
}
