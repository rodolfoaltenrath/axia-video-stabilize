const std = @import("std");
const rl = @import("raylib");
const ffmpeg_cli = @import("../legacy/ffmpeg_cli.zig");
const media = @import("../core/media.zig");

const max_preview_width: u32 = 960;
const max_preview_height: u32 = 540;
const max_preview_fps: f64 = 60;
const bytes_per_pixel: usize = 4;

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

        const info = try ffmpeg_cli.probe(self.allocator, input_path);
        const size = media.fitPreviewSize(
            info.width,
            info.height,
            max_preview_width,
            max_preview_height,
        );
        const pixel_count = std.math.mul(usize, size.width, size.height) catch
            return error.PreviewTooLarge;
        const byte_count = std.math.mul(usize, pixel_count, bytes_per_pixel) catch
            return error.PreviewTooLarge;

        self.path = try self.allocator.dupe(u8, input_path);
        self.pixels = try self.allocator.alloc(u8, byte_count);

        const image = rl.genImageColor(
            @intCast(size.width),
            @intCast(size.height),
            rl.Color.black,
        );
        defer rl.unloadImage(image);
        self.texture = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(self.texture.?, .bilinear);

        self.width = size.width;
        self.height = size.height;
        self.fps = @min(max_preview_fps, info.framesPerSecond());
        self.duration_seconds = info.duration_seconds;
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
        const executable_override = std.process.getEnvVarOwned(
            self.allocator,
            "AXIA_FFMPEG",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (executable_override) |path| self.allocator.free(path);
        const executable = executable_override orelse "ffmpeg";

        const seek_text = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{start_seconds});
        defer self.allocator.free(seek_text);
        const scale_filter = try std.fmt.allocPrint(
            self.allocator,
            "fps={d:.6},scale={d}:{d}:flags=fast_bilinear",
            .{ self.fps, self.width, self.height },
        );
        defer self.allocator.free(scale_filter);

        const argv = [_][]const u8{
            executable,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
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
        var reader = stdout.reader();
        while (true) {
            self.mutex.lock();
            while (self.frame_ready and !self.cancel_requested) {
                self.frame_consumed.wait(&self.mutex);
            }
            const cancelled = self.cancel_requested;
            self.mutex.unlock();
            if (cancelled) {
                _ = try child.kill();
                child_terminated = true;
                return;
            }

            reader.readNoEof(self.pixels.?) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            self.mutex.lock();
            if (self.cancel_requested) {
                self.mutex.unlock();
                _ = try child.kill();
                child_terminated = true;
                return;
            }
            self.frame_ready = true;
            self.mutex.unlock();
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
