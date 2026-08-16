const std = @import("std");
const builtin = @import("builtin");

pub const Command = struct {
    path: []const u8,
    owned_path: ?[]u8 = null,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        if (self.owned_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// Resolves the FFmpeg process in this order: explicit override, executable
/// directory and finally PATH. Keeping the bundled lookup here makes preview
/// and export use exactly the same executable.
pub fn resolve(allocator: std.mem.Allocator) error{OutOfMemory}!Command {
    const override = std.process.getEnvVarOwned(
        allocator,
        "AXIA_FFMPEG",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (override) |path| {
        if (path.len > 0) return .{ .path = path, .owned_path = path };
        allocator.free(path);
    }

    const executable_dir = std.fs.selfExeDirPathAlloc(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .path = defaultCommand() },
    };
    defer allocator.free(executable_dir);
    const candidate = std.fs.path.join(
        allocator,
        &.{ executable_dir, bundledFilename() },
    ) catch return error.OutOfMemory;
    std.fs.accessAbsolute(candidate, .{}) catch {
        allocator.free(candidate);
        return .{ .path = defaultCommand() };
    };
    return .{ .path = candidate, .owned_path = candidate };
}

pub fn bundledFilename() []const u8 {
    return if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
}

fn defaultCommand() []const u8 {
    return "ffmpeg";
}

test "bundled executable name follows the target platform" {
    const expected = if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
    try std.testing.expectEqualStrings(expected, bundledFilename());
}
