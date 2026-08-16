const std = @import("std");
const rl = @import("raylib");
const media = @import("../core/media.zig");
const decoder_mod = @import("../engine/decoder.zig");
const ffmpeg_command = @import("../platform/ffmpeg_command.zig");

const max_preview_width: u32 = 960;
const max_preview_height: u32 = 540;
const bytes_per_pixel: usize = 4;
const preview_pipe_poll_interval = 100 * std.time.ns_per_ms;

const PreviewPipe = enum { stdout };
const FrameReadResult = enum { frame, eof, cancelled };

pub const View = struct {
    texture: ?rl.Texture2D = null,
    width: u32 = 0,
    height: u32 = 0,
    duration_seconds: f64 = 0,
    position_seconds: f64 = 0,
    playing: bool = false,
    loaded: bool = false,
    ready: bool = false,
    failed: bool = false,

    pub fn progress(self: View) f32 {
        if (self.duration_seconds <= 0) return 0;
        return @floatCast(std.math.clamp(
            self.position_seconds / self.duration_seconds,
            0.0,
            1.0,
        ));
    }
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    frame_consumed: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    path: ?[]u8 = null,
    pixels: ?[]u8 = null,
    texture: ?rl.Texture2D = null,
    width: u32 = 0,
    height: u32 = 0,
    fps: f64 = 0,
    duration_seconds: f64 = 0,
    seek_origin_seconds: f64 = 0,
    position_seconds: f64 = 0,
    displayed_frames: u64 = 0,
    accumulator_seconds: f64 = 0,
    frame_ready: bool = false,
    has_displayed_frame: bool = false,
    playing: bool = false,
    eof: bool = false,
    failed: bool = false,
    cancel_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) Player {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Player) void {
        self.releaseMedia();
    }

    pub fn load(self: *Player, input_path: []const u8) !void {
        self.releaseMedia();
        errdefer self.releaseMedia();

        var metadata_decoder = try decoder_mod.Decoder.open(
            self.allocator,
            input_path,
            .{ .max_analysis_dimension = 2 },
        );
        defer metadata_decoder.deinit();
        const info = metadata_decoder.info;

        const display_dimensions = info.displayDimensions();
        const preview_size = media.fitPreviewSize(
            display_dimensions.width,
            display_dimensions.height,
            max_preview_width,
            max_preview_height,
        );
        self.width = preview_size.width;
        self.height = preview_size.height;

        const pixel_count = std.math.mul(usize, self.width, self.height) catch
            return error.PreviewTooLarge;
        const byte_count = std.math.mul(usize, pixel_count, bytes_per_pixel) catch
            return error.PreviewTooLarge;

        self.path = try self.allocator.dupe(u8, input_path);
        self.pixels = try self.allocator.alloc(u8, byte_count);

        const image = rl.genImageColor(
            @intCast(self.width),
            @intCast(self.height),
            rl.Color.black,
        );
        defer rl.unloadImage(image);
        self.texture = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(self.texture.?, .bilinear);

        const fps = info.framesPerSecond() orelse
            if (info.estimated_frame_count != null and
            info.duration_seconds != null and
            info.duration_seconds.? > 0)
            @as(f64, @floatFromInt(info.estimated_frame_count.?)) /
                info.duration_seconds.?
        else
            30;
        self.fps = media.fitPreviewFrameRate(fps);
        self.duration_seconds = info.duration_seconds orelse
            if (info.estimated_frame_count) |count|
            @as(f64, @floatFromInt(count)) / fps
        else
            return error.MissingMediaDuration;
        self.position_seconds = 0;
        self.playing = true;
        try self.startDecoder(0);
    }

    pub fn update(self: *Player, elapsed_seconds: f32) void {
        if (self.texture == null) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.playing) {
            self.accumulator_seconds += @min(@as(f64, @floatCast(elapsed_seconds)), 0.25);
        }

        const frame_interval = 1.0 / self.fps;
        const first_frame = !self.has_displayed_frame;
        const frame_due = self.playing and self.accumulator_seconds >= frame_interval;
        if (self.frame_ready and (first_frame or frame_due)) {
            rl.updateTexture(self.texture.?, self.pixels.?.ptr);
            self.frame_ready = false;
            self.has_displayed_frame = true;
            self.position_seconds = @min(
                self.duration_seconds,
                self.seek_origin_seconds +
                    @as(f64, @floatFromInt(self.displayed_frames)) / self.fps,
            );
            self.displayed_frames += 1;
            if (!first_frame) self.accumulator_seconds -= frame_interval;
            self.frame_consumed.signal();
        }

        if (self.eof and !self.frame_ready) {
            self.playing = false;
            self.position_seconds = self.duration_seconds;
        }
    }

    pub fn view(self: *Player) View {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .texture = self.texture,
            .width = self.width,
            .height = self.height,
            .duration_seconds = self.duration_seconds,
            .position_seconds = self.position_seconds,
            .playing = self.playing,
            .loaded = self.path != null,
            .ready = self.has_displayed_frame,
            .failed = self.failed,
        };
    }

    pub fn togglePlayback(self: *Player) !void {
        self.mutex.lock();
        const should_restart = self.eof;
        if (!should_restart) self.playing = !self.playing;
        self.mutex.unlock();

        if (should_restart) {
            try self.seek(0);
            self.mutex.lock();
            self.playing = true;
            self.mutex.unlock();
        }
    }

    pub fn pause(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.playing = false;
    }

    pub fn seek(self: *Player, requested_seconds: f64) !void {
        if (self.path == null) return;
        const target = std.math.clamp(requested_seconds, 0.0, self.duration_seconds);
        self.stopDecoder();

        self.mutex.lock();
        self.seek_origin_seconds = target;
        self.position_seconds = target;
        self.displayed_frames = 0;
        self.accumulator_seconds = 0;
        self.frame_ready = false;
        self.has_displayed_frame = false;
        self.eof = false;
        self.failed = false;
        self.cancel_requested = false;
        self.mutex.unlock();

        self.startDecoder(target) catch |err| {
            self.mutex.lock();
            self.failed = true;
            self.playing = false;
            self.mutex.unlock();
            return err;
        };
    }

    fn startDecoder(self: *Player, start_seconds: f64) !void {
        self.mutex.lock();
        self.cancel_requested = false;
        self.mutex.unlock();
        self.thread = try std.Thread.spawn(.{}, decodeMain, .{ self, start_seconds });
    }

    fn stopDecoder(self: *Player) void {
        const active_thread = self.thread orelse return;
        self.mutex.lock();
        self.cancel_requested = true;
        self.frame_consumed.broadcast();
        self.mutex.unlock();
        active_thread.join();
        self.thread = null;
    }

    fn cancellationRequested(self: *Player) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn readFrameInterruptibly(
        self: *Player,
        poller: anytype,
        destination: []u8,
    ) !FrameReadResult {
        // A bounded poll lets stopDecoder wake this thread before joining it,
        // even when FFmpeg has not produced enough bytes for a complete frame.
        var offset: usize = 0;
        while (offset < destination.len) {
            const fifo = poller.fifo(.stdout);
            offset += fifo.read(destination[offset..]);
            if (offset == destination.len) return .frame;
            if (self.cancellationRequested()) return .cancelled;

            const pipe_open = try poller.pollTimeout(preview_pipe_poll_interval);
            if (!pipe_open and poller.fifo(.stdout).count == 0) {
                return if (offset == 0) .eof else error.EndOfStream;
            }
        }
        return .frame;
    }

    fn releaseMedia(self: *Player) void {
        self.stopDecoder();
        if (self.texture) |texture| rl.unloadTexture(texture);
        if (self.pixels) |pixels| self.allocator.free(pixels);
        if (self.path) |path| self.allocator.free(path);
        self.texture = null;
        self.pixels = null;
        self.path = null;
        self.width = 0;
        self.height = 0;
        self.fps = 0;
        self.duration_seconds = 0;
        self.seek_origin_seconds = 0;
        self.position_seconds = 0;
        self.displayed_frames = 0;
        self.accumulator_seconds = 0;
        self.frame_ready = false;
        self.has_displayed_frame = false;
        self.playing = false;
        self.eof = false;
        self.failed = false;
        self.cancel_requested = false;
    }

    fn decodeMain(self: *Player, start_seconds: f64) void {
        self.decode(start_seconds) catch |err| {
            std.log.err("preview decoder failed: {s}", .{@errorName(err)});
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.cancel_requested) {
                self.failed = true;
                self.playing = false;
            }
        };
    }

    fn decode(self: *Player, start_seconds: f64) !void {
        var command = try ffmpeg_command.resolve(self.allocator);
        defer command.deinit(self.allocator);

        const seek_text = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{start_seconds});
        defer self.allocator.free(seek_text);

        const scale_filter = try std.fmt.allocPrint(
            self.allocator,
            "fps={d:.6},scale={d}:{d}",
            .{ self.fps, self.width, self.height },
        );
        defer self.allocator.free(scale_filter);

        const argv = [_][]const u8{
            command.path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-threads",
            "2",
            "-filter_threads",
            "2",
            "-filter_complex_threads",
            "2",
            "-ss",
            seek_text,
            "-i",
            self.path.?,
            "-map",
            "0:v:0",
            "-vf",
            scale_filter,
            "-an",
            "-sn",
            "-dn",
            "-pix_fmt",
            "rgba",
            "-f",
            "rawvideo",
            "pipe:1",
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.expand_arg0 = .expand;
        try child.spawn();

        var child_terminated = false;
        defer if (!child_terminated) {
            _ = child.kill() catch {};
        };

        const stdout = child.stdout orelse return error.MissingPreviewPipe;
        const decode_result: FrameReadResult = decode: {
            var poller = std.io.poll(self.allocator, PreviewPipe, .{ .stdout = stdout });
            defer poller.deinit();
            try poller.fifo(.stdout).ensureUnusedCapacity(self.pixels.?.len);

            while (true) {
                self.mutex.lock();
                while (self.frame_ready and !self.cancel_requested) {
                    self.frame_consumed.wait(&self.mutex);
                }
                const cancelled = self.cancel_requested;
                self.mutex.unlock();
                if (cancelled) break :decode .cancelled;

                switch (try self.readFrameInterruptibly(&poller, self.pixels.?)) {
                    .eof => break :decode .eof,
                    .cancelled => break :decode .cancelled,
                    .frame => {},
                }

                self.mutex.lock();
                if (self.cancel_requested) {
                    self.mutex.unlock();
                    break :decode .cancelled;
                }
                self.frame_ready = true;
                self.mutex.unlock();
            }
        };

        if (decode_result == .cancelled) {
            _ = try child.kill();
            child_terminated = true;
            return;
        }

        const term = try child.wait();
        child_terminated = true;
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.cancel_requested) {
            self.eof = true;
            if (!success) {
                self.failed = true;
                self.playing = false;
            }
        }
    }
};
