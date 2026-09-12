const std = @import("std");
const time = @import("time.zig");

pub const AssetId = enum(u64) {
    _,
};

pub const Error = error{
    EmptyPath,
    InvalidDuration,
} || time.Error || std.mem.Allocator.Error;

pub const MediaAsset = struct {
    allocator: std.mem.Allocator,
    id: AssetId,
    path: [:0]u8,
    duration: time.Time,
    has_audio: bool,

    pub fn create(
        allocator: std.mem.Allocator,
        id: AssetId,
        path: []const u8,
        duration: time.Time,
        has_audio: bool,
    ) Error!MediaAsset {
        if (path.len == 0) return error.EmptyPath;
        if (duration.scale == 0) return error.InvalidScale;
        if (duration.ticks <= 0) return error.InvalidDuration;
        return .{
            .allocator = allocator,
            .id = id,
            .path = try allocator.dupeZ(u8, path),
            .duration = duration,
            .has_audio = has_audio,
        };
    }

    pub fn deinit(self: *MediaAsset) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }
};
