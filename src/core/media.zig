const std = @import("std");

pub const MediaError = error{
    EmptyPath,
    UnsupportedFormat,
    OutputPathTooLong,
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
