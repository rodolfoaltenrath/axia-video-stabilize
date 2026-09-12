const std = @import("std");
const builtin = @import("builtin");

var runtime_io: ?std.Io = null;
var runtime_environ: ?*const std.process.Environ.Map = null;

pub fn init(runtime: std.Io, environ: *const std.process.Environ.Map) void {
    if (!builtin.is_test) {
        runtime_io = runtime;
        runtime_environ = environ;
    }
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return runtime_io orelse @panic("sync.init must be called before using synchronization primitives");
}

pub fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const environ = runtime_environ orelse return error.EnvironmentVariableNotFound;
    const value = environ.get(name) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

pub fn hasEnv(name: []const u8) bool {
    const environ = runtime_environ orelse return false;
    return environ.get(name) != null;
}

pub const ns_per_ms = 1_000_000;
pub const ns_per_s = 1_000_000_000;

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.now(.awake, io()).nanoseconds;
}

pub const Timer = struct {
    started_ns: i128,

    pub fn start() !Timer {
        return .{ .started_ns = nanoTimestamp() };
    }

    pub fn read(self: *Timer) u64 {
        const elapsed = nanoTimestamp() - self.started_ns;
        return if (elapsed <= 0) 0 else @intCast(elapsed);
    }
};

const TimedReadResult = union(enum) {
    read: std.Io.Reader.ShortError!usize,
    timeout: std.Io.Cancelable!void,
};

fn readSliceShort(reader: *std.Io.Reader, destination: []u8) std.Io.Reader.ShortError!usize {
    return reader.readSliceShort(destination);
}

fn waitForTimeout(nanoseconds: i96) std.Io.Cancelable!void {
    return std.Io.sleep(io(), .fromNanoseconds(nanoseconds), .awake);
}

/// Reads available stream data while retaining a bounded cancellation point.
/// A null result means the interval elapsed before the stream produced data.
pub fn readWithTimeout(
    reader: *std.Io.Reader,
    destination: []u8,
    timeout_nanoseconds: i96,
) !?usize {
    var results: [2]TimedReadResult = undefined;
    var select = std.Io.Select(TimedReadResult).init(io(), &results);
    defer select.cancelDiscard();
    select.async(.read, readSliceShort, .{ reader, destination });
    select.async(.timeout, waitForTimeout, .{timeout_nanoseconds});
    return switch (try select.await()) {
        .read => |result| try result,
        .timeout => |result| blk: {
            try result;
            break :blk null;
        },
    };
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(io(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};
