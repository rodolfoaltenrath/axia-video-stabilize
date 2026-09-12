const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../utils/sync.zig");

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
    const override = sync.getEnvOwned(
        allocator,
        "AXIA_FFMPEG",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (override) |path| {
        if (path.len > 0) return .{ .path = path, .owned_path = path };
        allocator.free(path);
    }

    const executable_dir = std.process.executableDirPathAlloc(sync.io(), allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .path = defaultCommand() },
    };
    defer allocator.free(executable_dir);
    const candidate = std.fs.path.join(
        allocator,
        &.{ executable_dir, bundledFilename() },
    ) catch return error.OutOfMemory;
    std.Io.Dir.accessAbsolute(sync.io(), candidate, .{}) catch {
        allocator.free(candidate);
        return .{ .path = defaultCommand() };
    };
    return .{ .path = candidate, .owned_path = candidate };
}

pub fn bundledFilename() []const u8 {
    return if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
}

/// Stops and reaps an FFmpeg child without waiting indefinitely for a graceful
/// shutdown. FFmpeg can ignore SIGTERM while blocked writing to a full pipe,
/// which would make std.process.Child.kill() wait forever on POSIX systems.
pub fn terminate(child: *std.process.Child) void {
    child.kill(sync.io());
}

fn defaultCommand() []const u8 {
    return "ffmpeg";
}

test "bundled executable name follows the target platform" {
    const expected = if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
    try std.testing.expectEqualStrings(expected, bundledFilename());
}
