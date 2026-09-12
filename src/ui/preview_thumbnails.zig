const std = @import("std");
const ffmpeg_command = @import("../platform/ffmpeg_command.zig");

pub const count: u32 = 10;
pub const maximum_cell_edge: u32 = 180;

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

const poll_interval = 100 * std.time.ns_per_ms;
const ProgressPipe = enum { progress };

pub const Status = enum { idle, waiting, building, ready, failed };

pub const Job = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    source_path: ?[]u8 = null,
    output_path: ?[]u8 = null,
    partial_path: ?[]u8 = null,
    duration_seconds: f64 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,
    status: Status = .idle,
    cancel_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) Job {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Job) void {
        self.reset();
    }

    pub fn prepare(
        self: *Job,
        source_path: []const u8,
        duration_seconds: f64,
        include_source_mtime: bool,
        preview_width: u32,
        preview_height: u32,
    ) !bool {
        self.reset();
        const paths = try thumbnailPaths(
            self.allocator,
            source_path,
            duration_seconds,
            include_source_mtime,
            preview_width,
            preview_height,
        );
        errdefer {
            self.allocator.free(paths.output);
            self.allocator.free(paths.partial);
        }
        self.source_path = try self.allocator.dupe(u8, source_path);
        self.output_path = paths.output;
        self.partial_path = paths.partial;
        self.duration_seconds = duration_seconds;
        const fitted_size = fitCellSize(preview_width, preview_height);
        self.cell_width = fitted_size.width;
        self.cell_height = fitted_size.height;
        if (validPng(paths.output)) {
            self.status = .ready;
            return true;
        }
        self.status = .waiting;
        return false;
    }

    pub fn start(self: *Job) !void {
        self.mutex.lock();
        if (self.thread != null or self.status != .waiting) {
            self.mutex.unlock();
            return;
        }
        self.status = .building;
        self.cancel_requested = false;
        self.mutex.unlock();
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.mutex.lock();
            self.status = .failed;
            self.mutex.unlock();
            return err;
        };
    }

    pub fn snapshot(self: *Job) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.status;
    }

    pub fn path(self: *const Job) ?[]const u8 {
        return self.output_path;
    }

    pub fn dimensions(self: *Job) Dimensions {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .width = self.cell_width, .height = self.cell_height };
    }

    pub fn finishCompletedThread(self: *Job) void {
        const active = self.thread orelse return;
        const state = self.snapshot();
        if (state != .ready and state != .failed) return;
        active.join();
        self.thread = null;
    }

    pub fn reset(self: *Job) void {
        if (self.thread) |active| {
            self.mutex.lock();
            self.cancel_requested = true;
            self.mutex.unlock();
            active.join();
            self.thread = null;
        }
        if (self.source_path) |value| self.allocator.free(value);
        if (self.output_path) |value| self.allocator.free(value);
        if (self.partial_path) |value| self.allocator.free(value);
        self.source_path = null;
        self.output_path = null;
        self.partial_path = null;
        self.duration_seconds = 0;
        self.cell_width = 0;
        self.cell_height = 0;
        self.status = .idle;
        self.cancel_requested = false;
    }

    fn cancelled(self: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn setTerminal(self: *Job, status: Status) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.cancel_requested) self.status = status;
    }

    fn workerMain(self: *Job) void {
        self.build() catch |err| {
            std.log.warn("preview thumbnails failed: {s}", .{@errorName(err)});
            self.setTerminal(.failed);
        };
    }

    fn build(self: *Job) !void {
        var command = try ffmpeg_command.resolve(self.allocator);
        defer command.deinit(self.allocator);
        const sample_fps = @as(f64, @floatFromInt(count)) /
            @max(0.001, self.duration_seconds);
        const filter = try std.fmt.allocPrint(
            self.allocator,
            "fps={d:.9},scale={d}:{d}:flags=lanczos,tile={d}x1",
            .{ sample_fps, self.cell_width, self.cell_height, count },
        );
        defer self.allocator.free(filter);
        const argv = [_][]const u8{
            command.path, "-hide_banner", "-loglevel", "error",            "-nostdin",
            "-threads",   "2",            "-i",        self.source_path.?, "-map",
            "0:v:0",      "-vf",          filter,      "-frames:v",        "1",
            "-an",        "-sn",          "-dn",       "-progress",        "pipe:1",
            "-nostats",   "-update",      "1",         "-y",               self.partial_path.?,
        };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.expand_arg0 = .expand;
        try child.spawn();
        var child_terminated = false;
        defer if (!child_terminated) ffmpeg_command.terminate(&child);

        const stdout = child.stdout orelse return error.MissingThumbnailProgressPipe;
        var poller = std.io.poll(self.allocator, ProgressPipe, .{ .progress = stdout });
        defer poller.deinit();
        while (true) {
            if (self.cancelled()) {
                ffmpeg_command.terminate(&child);
                child_terminated = true;
                return;
            }
            const pipe_open = try poller.pollTimeout(poll_interval);
            poller.fifo(.progress).discard(poller.fifo(.progress).count);
            if (!pipe_open) break;
        }
        const term = try child.wait();
        child_terminated = true;
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!success or !validPng(self.partial_path.?)) return error.ThumbnailEncodingFailed;
        try std.fs.renameAbsolute(self.partial_path.?, self.output_path.?);
        self.setTerminal(.ready);
    }
};

const Paths = struct { output: []u8, partial: []u8 };

fn thumbnailPaths(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    duration: f64,
    include_source_mtime: bool,
    preview_width: u32,
    preview_height: u32,
) !Paths {
    const stat = if (std.fs.path.isAbsolute(source_path)) blk: {
        var file = try std.fs.openFileAbsolute(source_path, .{});
        defer file.close();
        break :blk try file.stat();
    } else try std.fs.cwd().statFile(source_path);
    const identity = try std.fmt.allocPrint(
        allocator,
        "v2\x00{s}\x00{d}\x00{d}\x00{d:.6}\x00{d}x{d}x{d}",
        .{
            source_path,
            stat.size,
            if (include_source_mtime) stat.mtime else 0,
            duration,
            preview_width,
            preview_height,
            count,
        },
    );
    defer allocator.free(identity);
    const digest = std.hash.Wyhash.hash(0, identity);
    const filename = try std.fmt.allocPrint(allocator, "{x:0>16}.png", .{digest});
    defer allocator.free(filename);
    const root = try thumbnailCacheRoot(allocator);
    defer allocator.free(root);
    try std.fs.cwd().makePath(root);
    const output = try std.fs.path.join(allocator, &.{ root, filename });
    errdefer allocator.free(output);
    const partial = try std.fmt.allocPrint(allocator, "{s}.partial.png", .{output});
    return .{ .output = output, .partial = partial };
}

fn thumbnailCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |base| {
        defer allocator.free(base);
        if (base.len > 0) return std.fs.path.join(allocator, &.{ base, "axia", "thumbnails", "v2" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".cache", "axia", "thumbnails", "v2" });
}

pub fn fitCellSize(width: u32, height: u32) Dimensions {
    if (width == 0 or height == 0) return .{ .width = 2, .height = 2 };
    const scale = @min(
        1.0,
        @as(f64, @floatFromInt(maximum_cell_edge)) /
            @as(f64, @floatFromInt(@max(width, height))),
    );
    return .{
        .width = evenDimension(@intFromFloat(@max(
            2.0,
            @round(@as(f64, @floatFromInt(width)) * scale),
        ))),
        .height = evenDimension(@intFromFloat(@max(
            2.0,
            @round(@as(f64, @floatFromInt(height)) * scale),
        ))),
    };
}

pub fn indexForProgress(progress: f32) u32 {
    const bounded = std.math.clamp(progress, 0, 1);
    return @min(
        count - 1,
        @as(u32, @intFromFloat(@floor(
            bounded * @as(f32, @floatFromInt(count)),
        ))),
    );
}

fn evenDimension(value: u32) u32 {
    return if (value % 2 == 0) value else value + 1;
}

fn validPng(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    if (stat.kind != .file or stat.size < 128) return false;
    var signature: [8]u8 = undefined;
    const bytes_read = file.readAll(&signature) catch return false;
    return bytes_read == signature.len and
        std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n");
}

test "thumbnail sampling distributes ten frames over the clip" {
    const duration = 50.0;
    const sample_fps = @as(f64, @floatFromInt(count)) / duration;
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), sample_fps, 0.000001);
}

test "thumbnail cells retain landscape and portrait orientation" {
    try std.testing.expectEqual(
        Dimensions{ .width = 180, .height = 102 },
        fitCellSize(1920, 1080),
    );
    try std.testing.expectEqual(
        Dimensions{ .width = 102, .height = 180 },
        fitCellSize(1080, 1920),
    );
}

test "thumbnail selection clamps timeline boundaries" {
    try std.testing.expectEqual(@as(u32, 0), indexForProgress(-0.5));
    try std.testing.expectEqual(@as(u32, 5), indexForProgress(0.5));
    try std.testing.expectEqual(@as(u32, 9), indexForProgress(1.0));
}
