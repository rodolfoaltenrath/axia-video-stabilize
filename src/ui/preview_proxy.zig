const std = @import("std");
const builtin = @import("builtin");
const ffmpeg_command = @import("../platform/ffmpeg_command.zig");

const poll_interval = 100 * std.time.ns_per_ms;
const maximum_cache_bytes: u64 = 5 * 1024 * 1024 * 1024;
const ProxyPipe = enum { progress };

pub const Status = enum {
    idle,
    waiting_for_poster,
    building,
    ready,
    failed,
};

pub const Snapshot = struct {
    status: Status,
    progress: f32,
};

pub const Options = struct {
    source_width: u32,
    source_height: u32,
    width: u32,
    height: u32,
    fps: f64,
    duration_seconds: f64,
    hdr: bool,
};

/// Owns one cancellable proxy job. Source media remains untouched; only a
/// versioned file under the user's cache directory is published.
pub const Job = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    source_path: ?[]u8 = null,
    output_path: ?[]u8 = null,
    partial_path: ?[]u8 = null,
    options: Options = undefined,
    status: Status = .idle,
    progress: f32 = 0,
    cancel_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) Job {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Job) void {
        self.reset();
    }

    /// Prepares paths and returns true when a valid cached proxy already
    /// exists. Call `start` only when this returns false.
    pub fn prepare(
        self: *Job,
        source_path: []const u8,
        options: Options,
    ) !bool {
        self.reset();
        const paths = try proxyPaths(self.allocator, source_path, options);
        errdefer {
            self.allocator.free(paths.output);
            self.allocator.free(paths.partial);
        }
        self.source_path = try self.allocator.dupe(u8, source_path);
        self.output_path = paths.output;
        self.partial_path = paths.partial;
        self.options = options;

        if (absoluteFileIsUsable(paths.output)) {
            touchCacheEntry(paths.output);
            self.status = .ready;
            self.progress = 1;
            return true;
        }
        self.status = .waiting_for_poster;
        return false;
    }

    pub fn start(self: *Job) !void {
        self.mutex.lock();
        if (self.thread != null or self.status != .waiting_for_poster) {
            self.mutex.unlock();
            return;
        }
        self.status = .building;
        self.progress = 0;
        self.cancel_requested = false;
        self.mutex.unlock();

        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.mutex.lock();
            self.status = .failed;
            self.mutex.unlock();
            return err;
        };
    }

    pub fn snapshot(self: *Job) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .status = self.status, .progress = self.progress };
    }

    pub fn finishCompletedThread(self: *Job) void {
        const active = self.thread orelse return;
        const state = self.snapshot().status;
        if (state != .ready and state != .failed) return;
        active.join();
        self.thread = null;
    }

    pub fn path(self: *const Job) ?[]const u8 {
        return self.output_path;
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
        self.status = .idle;
        self.progress = 0;
        self.cancel_requested = false;
    }

    fn cancelled(self: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn setProgress(self: *Job, value: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.progress = @max(self.progress, std.math.clamp(value, 0, 0.99));
    }

    fn setTerminalStatus(self: *Job, status: Status) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.cancel_requested) {
            self.status = status;
            if (status == .ready) self.progress = 1;
        }
    }

    fn workerMain(self: *Job) void {
        self.build() catch |err| {
            std.log.err("preview proxy failed: {s}", .{@errorName(err)});
            self.setTerminalStatus(.failed);
        };
    }

    fn build(self: *Job) !void {
        var command = try ffmpeg_command.resolve(self.allocator);
        defer command.deinit(self.allocator);

        const cache_root = std.fs.path.dirname(self.output_path.?) orelse
            return error.InvalidProxyPath;
        pruneCache(self.allocator, cache_root, self.output_path.?, maximum_cache_bytes) catch |err| {
            std.log.warn("could not prune preview cache: {s}", .{@errorName(err)});
        };

        const fps_text = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{self.options.fps});
        defer self.allocator.free(fps_text);
        const dimensions = try std.fmt.allocPrint(
            self.allocator,
            "{d}:{d}",
            .{ self.options.width, self.options.height },
        );
        defer self.allocator.free(dimensions);
        const filter = try buildFilter(
            self.allocator,
            self.options,
            fps_text,
            dimensions,
        );
        defer self.allocator.free(filter);
        const gop = try std.fmt.allocPrint(
            self.allocator,
            "{d}",
            .{@as(u32, @intFromFloat(@max(1, @round(self.options.fps))))},
        );
        defer self.allocator.free(gop);

        const argv = [_][]const u8{
            command.path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-filter_threads",
            "2",
            "-progress",
            "pipe:1",
            "-nostats",
            "-threads",
            "4",
            "-i",
            self.source_path.?,
            "-map",
            "0:v:0",
            "-vf",
            filter,
            "-an",
            "-sn",
            "-dn",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            "-preset",
            "veryfast",
            "-tune",
            "fastdecode",
            "-crf",
            "19",
            "-g",
            gop,
            "-keyint_min",
            gop,
            "-sc_threshold",
            "0",
            "-movflags",
            "+faststart",
            "-y",
            self.partial_path.?,
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.expand_arg0 = .expand;
        try child.spawn();

        var child_terminated = false;
        defer if (!child_terminated) {
            ffmpeg_command.terminate(&child);
        };

        const stdout = child.stdout orelse return error.MissingProgressPipe;
        var poller = std.io.poll(self.allocator, ProxyPipe, .{ .progress = stdout });
        defer poller.deinit();
        try poller.fifo(.progress).ensureUnusedCapacity(4096);

        while (true) {
            if (self.cancelled()) {
                ffmpeg_command.terminate(&child);
                child_terminated = true;
                return;
            }
            const pipe_open = try poller.pollTimeout(poll_interval);
            parseProgress(self, poller.fifo(.progress));
            if (!pipe_open and poller.fifo(.progress).count == 0) break;
        }

        const term = try child.wait();
        child_terminated = true;
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!success or !absoluteFileIsUsable(self.partial_path.?)) {
            return error.ProxyEncodingFailed;
        }
        try std.fs.renameAbsolute(self.partial_path.?, self.output_path.?);
        pruneCache(self.allocator, cache_root, self.output_path.?, maximum_cache_bytes) catch |err| {
            std.log.warn("could not prune preview cache: {s}", .{@errorName(err)});
        };
        self.setTerminalStatus(.ready);
    }
};

const ProxyPaths = struct {
    output: []u8,
    partial: []u8,
};

fn proxyPaths(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    options: Options,
) !ProxyPaths {
    const stat = if (std.fs.path.isAbsolute(source_path)) blk: {
        var file = try std.fs.openFileAbsolute(source_path, .{});
        defer file.close();
        break :blk try file.stat();
    } else try std.fs.cwd().statFile(source_path);
    const identity = try std.fmt.allocPrint(
        allocator,
        "v2\x00{s}\x00{d}\x00{d}\x00{d}x{d}\x00{d}x{d}\x00{d:.6}\x00{}",
        .{
            source_path,
            stat.size,
            stat.mtime,
            options.source_width,
            options.source_height,
            options.width,
            options.height,
            options.fps,
            options.hdr,
        },
    );
    defer allocator.free(identity);
    const digest = std.hash.Wyhash.hash(0, identity);
    const filename = try std.fmt.allocPrint(allocator, "{x:0>16}.mp4", .{digest});
    defer allocator.free(filename);

    const root = try proxyCacheRoot(allocator);
    defer allocator.free(root);
    try std.fs.cwd().makePath(root);
    const output = try std.fs.path.join(allocator, &.{ root, filename });
    errdefer allocator.free(output);
    const partial = try std.fmt.allocPrint(allocator, "{s}.partial.mp4", .{output});
    return .{ .output = output, .partial = partial };
}

fn proxyCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |base| {
        defer allocator.free(base);
        if (base.len > 0) return std.fs.path.join(allocator, &.{ base, "axia", "proxies", "v2" });
    } else |_| {}

    if (builtin.os.tag == .windows) {
        const base = try std.fs.getAppDataDir(allocator, "Axia");
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, "cache", "proxies", "v2" });
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".cache", "axia", "proxies", "v2" });
}

fn buildFilter(
    allocator: std.mem.Allocator,
    options: Options,
    fps_text: []const u8,
    dimensions: []const u8,
) ![]u8 {
    if (!options.hdr) {
        return std.fmt.allocPrint(
            allocator,
            "fps={s},scale={s}:flags=lanczos,format=yuv420p",
            .{ fps_text, dimensions },
        );
    }

    // Tone mapping a 4K/8K float frame is disproportionately expensive. Work
    // at twice the final preview resolution to retain fine highlight detail,
    // then perform the final Lanczos reduction after conversion to BT.709.
    const doubled_width = std.math.mul(u32, options.width, 2) catch std.math.maxInt(u32);
    const doubled_height = std.math.mul(u32, options.height, 2) catch std.math.maxInt(u32);
    const tone_width = @min(options.source_width, doubled_width);
    const tone_height = @min(options.source_height, doubled_height);
    return std.fmt.allocPrint(
        allocator,
        "fps={s},zscale=w={d}:h={d}:filter=lanczos:transfer=linear:npl=100," ++
            "format=gbrpf32le,zscale=primaries=bt709," ++
            "tonemap=tonemap=mobius:desat=0," ++
            "zscale=transfer=bt709:matrix=bt709:range=limited," ++
            "scale={s}:flags=lanczos,format=yuv420p",
        .{ fps_text, tone_width, tone_height, dimensions },
    );
}

fn absoluteFileIsUsable(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    if (stat.kind != .file or stat.size < 1024) return false;

    var header: [12]u8 = undefined;
    const bytes_read = file.readAll(&header) catch return false;
    return bytes_read == header.len and std.mem.eql(u8, header[4..8], "ftyp");
}

fn touchCacheEntry(path: []const u8) void {
    var file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const now = std.time.nanoTimestamp();
    file.updateTimes(now, now) catch {};
}

const CacheEntry = struct {
    name: []u8,
    size: u64,
    mtime: i128,
    preserved: bool,
};

fn pruneCache(
    allocator: std.mem.Allocator,
    root: []const u8,
    preserved_path: []const u8,
    maximum_bytes: u64,
) !void {
    var directory = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer directory.close();

    var entries = std.ArrayList(CacheEntry).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit();
    }

    const preserved_name = std.fs.path.basename(preserved_path);
    var total_size: u64 = 0;
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.name, ".mp4") or
            std.mem.endsWith(u8, entry.name, ".partial.mp4"))
        {
            continue;
        }
        const stat = directory.statFile(entry.name) catch continue;
        total_size +|= stat.size;
        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);
        try entries.append(.{
            .name = owned_name,
            .size = stat.size,
            .mtime = stat.mtime,
            .preserved = std.mem.eql(u8, entry.name, preserved_name),
        });
    }
    if (total_size <= maximum_bytes) return;

    std.mem.sort(CacheEntry, entries.items, {}, struct {
        fn lessThan(_: void, left: CacheEntry, right: CacheEntry) bool {
            return left.mtime < right.mtime;
        }
    }.lessThan);
    for (entries.items) |entry| {
        if (total_size <= maximum_bytes) break;
        if (entry.preserved) continue;
        directory.deleteFile(entry.name) catch continue;
        total_size -= entry.size;
    }
}

fn parseProgress(job: *Job, fifo: anytype) void {
    fifo.realign();
    while (true) {
        const available = fifo.readableSlice(0);
        const newline = std.mem.indexOfScalar(u8, available, '\n') orelse return;
        const raw_line = std.mem.trimRight(u8, available[0..newline], "\r");
        if (std.mem.startsWith(u8, raw_line, "out_time_us=")) {
            const value = std.fmt.parseInt(u64, raw_line["out_time_us=".len..], 10) catch 0;
            if (job.options.duration_seconds > 0) {
                const seconds = @as(f64, @floatFromInt(value)) / 1_000_000.0;
                job.setProgress(@floatCast(seconds / job.options.duration_seconds));
            }
        } else if (std.mem.startsWith(u8, raw_line, "frame=")) {
            const frame = std.fmt.parseInt(u64, raw_line["frame=".len..], 10) catch 0;
            const total_frames = job.options.duration_seconds * job.options.fps;
            if (total_frames > 0) {
                job.setProgress(@floatCast(
                    @as(f64, @floatFromInt(frame)) / total_frames,
                ));
            }
        }
        fifo.discard(newline + 1);
    }
}

test "proxy progress follows encoded media time" {
    var job = Job.init(std.testing.allocator);
    job.options = .{
        .source_width = 1920,
        .source_height = 1080,
        .width = 960,
        .height = 540,
        .fps = 30,
        .duration_seconds = 10,
        .hdr = false,
    };
    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(std.testing.allocator);
    defer fifo.deinit();
    try fifo.writer().writeAll("frame=75\nout_time_us=2500000\nprogress=continue\n");

    parseProgress(&job, &fifo);

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), job.snapshot().progress, 0.0001);
    try std.testing.expectEqual(@as(usize, 0), fifo.count);
}

test "HDR proxy limits float tone mapping to twice the preview size" {
    const filter = try buildFilter(std.testing.allocator, .{
        .source_width = 2160,
        .source_height = 3840,
        .width = 540,
        .height = 960,
        .fps = 24,
        .duration_seconds = 10,
        .hdr = true,
    }, "24.000000", "540:960");
    defer std.testing.allocator.free(filter);

    try std.testing.expect(std.mem.indexOf(
        u8,
        filter,
        "zscale=w=1080:h=1920:filter=lanczos:transfer=linear",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        filter,
        "scale=540:960:flags=lanczos,format=yuv420p",
    ));
}

test "proxy cache removes least recently used entries and preserves active output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const names = [_][]const u8{ "old.mp4", "recent.mp4", "active.mp4" };
    for (names, 0..) |name, index| {
        var file = try temporary.dir.createFile(name, .{});
        defer file.close();
        try file.writeAll("0123456789abcdef");
        const timestamp: i128 = @intCast(index + 1);
        try file.updateTimes(timestamp, timestamp);
    }

    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const preserved = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "active.mp4" },
    );
    defer std.testing.allocator.free(preserved);

    try pruneCache(std.testing.allocator, root, preserved, 32);

    try std.testing.expectError(error.FileNotFound, temporary.dir.access("old.mp4", .{}));
    try temporary.dir.access("recent.mp4", .{});
    try temporary.dir.access("active.mp4", .{});
}
