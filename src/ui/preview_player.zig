const std = @import("std");
const sync = @import("../utils/sync.zig");
const rl = @import("raylib");
const media = @import("../core/media.zig");
const decoder_mod = @import("../engine/decoder.zig");
const ffmpeg_command = @import("../platform/ffmpeg_command.zig");
const frame_queue = @import("frame_queue.zig");
const preview_proxy = @import("preview_proxy.zig");
const preview_thumbnails = @import("preview_thumbnails.zig");

const bytes_per_pixel: usize = 4;
const frame_queue_capacity = frame_queue.capacity;
const preview_pipe_poll_interval = 100 * sync.ns_per_ms;
const seek_debounce_seconds: f64 = 0.08;

const PreviewPipe = enum { stdout };
const FrameReadResult = enum { frame, eof, cancelled };

const FrameTiming = frame_queue.Timing;

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
    diagnostics_enabled: bool = false,
    decoded_frames: u64 = 0,
    decode_pipeline_ms: f64 = 0,
    upload_ms: f64 = 0,
    preparing_proxy: bool = false,
    proxy_progress: f32 = 0,
    proxy_failed: bool = false,
    using_proxy: bool = false,
    queued_frames: usize = 0,
    dropped_frames: u64 = 0,
    underruns: u64 = 0,
    seeking: bool = false,
    thumbnail_texture: ?rl.Texture2D = null,
    thumbnail_count: u32 = 0,
    thumbnail_cell_width: u32 = 0,
    thumbnail_cell_height: u32 = 0,

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
    mutex: sync.Mutex = .{},
    queue_space_available: sync.Condition = .{},
    thread: ?std.Thread = null,
    decoder_finished: bool = true,
    waiting_to_start_proxy: bool = false,
    pending_decoder_start: ?f64 = null,
    pending_playing: bool = false,
    pending_seek_delay_seconds: f64 = 0,
    decode_generation: u64 = 0,
    scrub_preview_active: bool = false,
    path: ?[]u8 = null,
    frame_storage: ?[]u8 = null,
    frame_byte_count: usize = 0,
    frame_timings: [frame_queue_capacity]FrameTiming = [_]FrameTiming{.{}} ** frame_queue_capacity,
    queue_read_index: usize = 0,
    queue_count: usize = 0,
    texture: ?rl.Texture2D = null,
    thumbnail_texture: ?rl.Texture2D = null,
    width: u32 = 0,
    height: u32 = 0,
    fps: f64 = 0,
    duration_seconds: f64 = 0,
    seek_origin_seconds: f64 = 0,
    position_seconds: f64 = 0,
    playback_clock_seconds: f64 = 0,
    has_displayed_frame: bool = false,
    playing: bool = false,
    eof: bool = false,
    failed: bool = false,
    cancel_requested: bool = false,
    diagnostics_enabled: bool = false,
    decoded_frames: u64 = 0,
    decode_pipeline_ns: u64 = 0,
    uploaded_frames: u64 = 0,
    upload_ns: u64 = 0,
    dropped_frames: u64 = 0,
    underruns: u64 = 0,
    proxy: preview_proxy.Job,
    thumbnails: preview_thumbnails.Job,
    thumbnails_loaded_or_failed: bool = false,
    using_proxy: bool = false,
    proxy_failure_handled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Player {
        return .{
            .allocator = allocator,
            .diagnostics_enabled = sync.hasEnv(
                "AXIA_PREVIEW_DIAGNOSTICS",
            ),
            .proxy = preview_proxy.Job.init(allocator),
            .thumbnails = preview_thumbnails.Job.init(allocator),
        };
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
        const fps = info.framesPerSecond() orelse
            if (info.estimated_frame_count != null and
                info.duration_seconds != null and
                info.duration_seconds.? > 0)
                @as(f64, @floatFromInt(info.estimated_frame_count.?)) /
                    info.duration_seconds.?
            else
                30;
        const profile = media.previewProfile(.{
            .width = display_dimensions.width,
            .height = display_dimensions.height,
            .frames_per_second = fps,
            .bit_rate = info.bit_rate,
            .hdr = info.source_is_hdr,
        });
        const preview_size = media.fitOrientedPreviewSize(
            display_dimensions.width,
            display_dimensions.height,
            profile.maximum_long_edge,
            profile.maximum_short_edge,
        );
        self.width = preview_size.width;
        self.height = preview_size.height;

        const pixel_count = std.math.mul(usize, self.width, self.height) catch
            return error.PreviewTooLarge;
        const byte_count = std.math.mul(usize, pixel_count, bytes_per_pixel) catch
            return error.PreviewTooLarge;

        self.path = try self.allocator.dupe(u8, input_path);
        const queue_byte_count = std.math.mul(
            usize,
            byte_count,
            frame_queue_capacity,
        ) catch return error.PreviewTooLarge;
        self.frame_storage = try self.allocator.alloc(u8, queue_byte_count);
        self.frame_byte_count = byte_count;

        const image = rl.genImageColor(
            @intCast(self.width),
            @intCast(self.height),
            rl.Color.black,
        );
        defer rl.unloadImage(image);
        self.texture = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(self.texture.?, .bilinear);

        self.fps = media.fitPreviewFrameRateForProfile(fps, profile);
        self.duration_seconds = info.duration_seconds orelse
            if (info.estimated_frame_count) |count|
                @as(f64, @floatFromInt(count)) / fps
            else
                return error.MissingMediaDuration;
        self.position_seconds = 0;
        self.playback_clock_seconds = 0;
        self.decode_generation = 1;
        if (profile.proxy_recommended) {
            const cached = try self.proxy.prepare(input_path, .{
                .source_width = display_dimensions.width,
                .source_height = display_dimensions.height,
                .width = self.width,
                .height = self.height,
                .fps = self.fps,
                .duration_seconds = self.duration_seconds,
                .hdr = info.source_is_hdr,
            });
            if (cached) {
                self.using_proxy = true;
                self.playing = true;
            } else {
                // Decode only until the first poster reaches the UI. The
                // source decoder is then stopped before proxy generation so
                // two expensive decoders never compete for CPU and memory.
                self.playing = false;
            }
        } else {
            self.playing = true;
        }
        try self.startDecoder(0);
        if (self.using_proxy) {
            self.prepareThumbnails(self.proxy.path().?, false);
        } else if (!profile.proxy_recommended) {
            self.prepareThumbnails(input_path, true);
        }
    }

    pub fn update(self: *Player, elapsed_seconds: f32) void {
        if (self.texture == null) return;

        self.advancePendingSeek(elapsed_seconds);
        self.continueProxyTransition();
        self.activateProxyIfFinished();
        self.continueDecoderRestart();
        self.activateThumbnailsIfFinished();

        self.mutex.lock();
        var start_proxy = false;

        self.discardStaleFramesLocked();

        if (self.playing) {
            const elapsed = @as(f64, @floatCast(elapsed_seconds));
            if (std.math.isFinite(elapsed) and elapsed > 0) {
                self.playback_clock_seconds = @min(
                    self.duration_seconds,
                    self.playback_clock_seconds + elapsed,
                );
                self.position_seconds = self.playback_clock_seconds;
            }
        }

        const frames_due = self.framesDue();
        if (frames_due > 0) {
            const selected_offset = frames_due - 1;
            const selected_index = (self.queue_read_index + selected_offset) %
                frame_queue_capacity;
            var upload_timer: ?sync.Timer = sync.Timer.start() catch null;
            rl.updateTexture(self.texture.?, self.framePixels(selected_index).ptr);
            if (upload_timer) |*timer| {
                self.upload_ns +|= timer.read();
                self.uploaded_frames +|= 1;
            }
            if (frames_due > 1) self.dropped_frames +|= frames_due - 1;
            self.queue_read_index = (self.queue_read_index + frames_due) %
                frame_queue_capacity;
            self.queue_count -= frames_due;
            self.has_displayed_frame = true;
            self.scrub_preview_active = false;
            self.queue_space_available.broadcast();
            if (self.proxy.snapshot().status == .waiting_for_poster) {
                start_proxy = true;
                self.playing = false;
            }
        } else if (self.playing and self.queue_count == 0 and !self.eof) {
            self.underruns +|= 1;
        }

        const proxy_state = self.proxy.snapshot().status;
        if (self.eof and self.queue_count == 0 and
            proxy_state != .waiting_for_poster and proxy_state != .building)
        {
            self.playing = false;
            self.position_seconds = self.duration_seconds;
        }
        self.mutex.unlock();

        if (start_proxy) {
            self.mutex.lock();
            self.waiting_to_start_proxy = true;
            self.mutex.unlock();
            self.requestDecoderStop();
        }
    }

    pub fn view(self: *Player) View {
        const proxy_snapshot = self.proxy.snapshot();
        const thumbnail_dimensions = self.thumbnails.dimensions();
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
            .diagnostics_enabled = self.diagnostics_enabled,
            .decoded_frames = self.decoded_frames,
            .decode_pipeline_ms = averageMilliseconds(
                self.decode_pipeline_ns,
                self.decoded_frames,
            ),
            .upload_ms = averageMilliseconds(
                self.upload_ns,
                self.uploaded_frames,
            ),
            .preparing_proxy = proxy_snapshot.status == .waiting_for_poster or
                proxy_snapshot.status == .building,
            .proxy_progress = proxy_snapshot.progress,
            .proxy_failed = proxy_snapshot.status == .failed,
            .using_proxy = self.using_proxy,
            .queued_frames = self.queue_count,
            .dropped_frames = self.dropped_frames,
            .underruns = self.underruns,
            .seeking = self.pending_decoder_start != null or self.scrub_preview_active,
            .thumbnail_texture = self.thumbnail_texture,
            .thumbnail_count = if (self.thumbnail_texture != null) preview_thumbnails.count else 0,
            .thumbnail_cell_width = thumbnail_dimensions.width,
            .thumbnail_cell_height = thumbnail_dimensions.height,
        };
    }

    pub fn togglePlayback(self: *Player) !void {
        const proxy_state = self.proxy.snapshot().status;
        if (proxy_state == .waiting_for_poster or proxy_state == .building) return;
        self.mutex.lock();
        if (self.pending_decoder_start != null) {
            self.pending_playing = !self.pending_playing;
            self.mutex.unlock();
            return;
        }
        const should_restart = self.eof;
        if (!should_restart) self.playing = !self.playing;
        self.mutex.unlock();

        if (should_restart) {
            try self.seek(0);
            self.mutex.lock();
            if (self.pending_decoder_start != null) {
                self.pending_playing = true;
            } else {
                self.playing = true;
            }
            self.mutex.unlock();
        }
    }

    pub fn pause(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.playing = false;
        self.pending_playing = false;
    }

    pub fn seek(self: *Player, requested_seconds: f64) !void {
        if (self.path == null) return;
        const proxy_state = self.proxy.snapshot().status;
        if (proxy_state == .waiting_for_poster or proxy_state == .building) return;
        const target = std.math.clamp(requested_seconds, 0.0, self.duration_seconds);

        self.mutex.lock();
        const resume_playback = if (self.pending_decoder_start != null)
            self.pending_playing
        else
            self.playing;
        self.decode_generation +%= 1;
        self.seek_origin_seconds = target;
        self.position_seconds = target;
        self.playback_clock_seconds = target;
        self.resetFrameQueueLocked();
        self.has_displayed_frame = false;
        self.eof = false;
        self.failed = false;
        self.cancel_requested = false;
        self.decoded_frames = 0;
        self.decode_pipeline_ns = 0;
        self.uploaded_frames = 0;
        self.upload_ns = 0;
        self.dropped_frames = 0;
        self.underruns = 0;
        self.pending_decoder_start = target;
        self.pending_playing = resume_playback;
        self.pending_seek_delay_seconds = seek_debounce_seconds;
        self.scrub_preview_active = true;
        self.playing = false;
        if (self.thread != null) self.cancel_requested = true;
        self.queue_space_available.broadcast();
        self.mutex.unlock();
    }

    fn startDecoder(self: *Player, start_seconds: f64) !void {
        self.mutex.lock();
        self.cancel_requested = false;
        self.decoder_finished = false;
        const generation = self.decode_generation;
        self.mutex.unlock();
        self.thread = std.Thread.spawn(.{}, decodeMain, .{ self, start_seconds, generation }) catch |err| {
            self.mutex.lock();
            self.decoder_finished = true;
            self.mutex.unlock();
            return err;
        };
    }

    fn stopDecoder(self: *Player) void {
        const active_thread = self.thread orelse return;
        self.requestDecoderStop();
        active_thread.join();
        self.thread = null;
    }

    fn requestDecoderStop(self: *Player) void {
        if (self.thread == null) return;
        self.mutex.lock();
        self.cancel_requested = true;
        self.queue_space_available.broadcast();
        self.mutex.unlock();
    }

    fn cancellationRequested(self: *Player) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn readFrameInterruptibly(
        self: *Player,
        reader: *std.Io.File.Reader,
        destination: []u8,
    ) !FrameReadResult {
        var offset: usize = 0;
        while (offset < destination.len) {
            if (self.cancellationRequested()) return .cancelled;
            const read = try sync.readWithTimeout(
                reader,
                destination[offset..],
                preview_pipe_poll_interval,
            ) orelse continue;
            if (read == 0) return if (offset == 0) .eof else error.EndOfStream;
            offset += read;
        }
        return .frame;
    }

    fn releaseMedia(self: *Player) void {
        self.stopDecoder();
        self.thumbnails.reset();
        self.proxy.reset();
        if (self.texture) |texture| rl.unloadTexture(texture);
        if (self.thumbnail_texture) |texture| rl.unloadTexture(texture);
        if (self.frame_storage) |storage| self.allocator.free(storage);
        if (self.path) |path| self.allocator.free(path);
        self.texture = null;
        self.thumbnail_texture = null;
        self.thumbnails_loaded_or_failed = false;
        self.frame_storage = null;
        self.frame_byte_count = 0;
        self.path = null;
        self.width = 0;
        self.height = 0;
        self.fps = 0;
        self.duration_seconds = 0;
        self.seek_origin_seconds = 0;
        self.position_seconds = 0;
        self.playback_clock_seconds = 0;
        self.resetFrameQueueLocked();
        self.has_displayed_frame = false;
        self.playing = false;
        self.eof = false;
        self.failed = false;
        self.cancel_requested = false;
        self.decoded_frames = 0;
        self.decode_pipeline_ns = 0;
        self.uploaded_frames = 0;
        self.upload_ns = 0;
        self.dropped_frames = 0;
        self.underruns = 0;
        self.using_proxy = false;
        self.proxy_failure_handled = false;
        self.decoder_finished = true;
        self.waiting_to_start_proxy = false;
        self.pending_decoder_start = null;
        self.pending_playing = false;
        self.pending_seek_delay_seconds = 0;
        self.decode_generation = 0;
        self.scrub_preview_active = false;
    }

    fn decodeMain(self: *Player, start_seconds: f64, generation: u64) void {
        defer {
            self.mutex.lock();
            self.decoder_finished = true;
            self.mutex.unlock();
        }
        self.decode(start_seconds, generation) catch |err| {
            std.log.err("preview decoder failed: {s}", .{@errorName(err)});
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.cancel_requested) {
                self.failed = true;
                self.playing = false;
            }
        };
    }

    fn decode(self: *Player, start_seconds: f64, generation: u64) !void {
        var command = try ffmpeg_command.resolve(self.allocator);
        defer command.deinit(self.allocator);

        const seek_text = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{start_seconds});
        defer self.allocator.free(seek_text);

        const scale_filter = try std.fmt.allocPrint(
            self.allocator,
            "fps={d:.6},scale={d}:{d}:flags=bicubic+accurate_rnd",
            .{ self.fps, self.width, self.height },
        );
        defer self.allocator.free(scale_filter);

        const input_path = if (self.using_proxy)
            self.proxy.path() orelse return error.MissingPreviewProxy
        else
            self.path.?;
        const argv = [_][]const u8{
            command.path,
            "-hide_banner",
            "-loglevel",
            // Normal cancellation closes the raw-video pipe before FFmpeg's
            // muxer finishes. Only fatal diagnostics belong in the terminal;
            // ordinary broken-pipe messages are expected during shutdown.
            "fatal",
            "-nostdin",
            "-threads",
            "0",
            "-filter_threads",
            "4",
            "-hwaccel",
            "auto",
            "-ss",
            seek_text,
            "-i",
            input_path,
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

        var child = try std.process.spawn(sync.io(), .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .expand_arg0 = .expand,
        });

        var child_terminated = false;
        defer if (!child_terminated) {
            ffmpeg_command.terminate(&child);
        };

        const stdout = child.stdout orelse return error.MissingPreviewPipe;
        const decode_result: FrameReadResult = decode: {
            var read_buffer: [64 * 1024]u8 = undefined;
            var file_reader = stdout.readerStreaming(sync.io(), &read_buffer);
            var decoded_index: u64 = 0;

            while (true) {
                self.mutex.lock();
                while (self.queue_count == frame_queue_capacity and !self.cancel_requested) {
                    self.queue_space_available.wait(&self.mutex);
                }
                const cancelled = self.cancel_requested;
                const write_index = (self.queue_read_index + self.queue_count) %
                    frame_queue_capacity;
                self.mutex.unlock();
                if (cancelled) break :decode .cancelled;

                var decode_timer = try sync.Timer.start();
                switch (try self.readFrameInterruptibly(
                    &file_reader,
                    self.framePixels(write_index),
                )) {
                    .eof => break :decode .eof,
                    .cancelled => break :decode .cancelled,
                    .frame => {},
                }
                const decode_ns = decode_timer.read();

                self.mutex.lock();
                if (self.cancel_requested or generation != self.decode_generation) {
                    self.mutex.unlock();
                    break :decode .cancelled;
                }
                self.decoded_frames +|= 1;
                self.decode_pipeline_ns +|= decode_ns;
                self.frame_timings[write_index] = .{
                    .pts_seconds = @min(
                        self.duration_seconds,
                        start_seconds +
                            @as(f64, @floatFromInt(decoded_index)) / self.fps,
                    ),
                    .duration_seconds = 1.0 / self.fps,
                    .generation = generation,
                };
                decoded_index +|= 1;
                self.queue_count += 1;
                self.mutex.unlock();
            }
        };

        if (decode_result == .cancelled) {
            ffmpeg_command.terminate(&child);
            child_terminated = true;
            return;
        }

        const term = try child.wait(sync.io());
        child_terminated = true;
        const success = switch (term) {
            .exited => |code| code == 0,
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

    fn activateProxyIfFinished(self: *Player) void {
        const proxy_state = self.proxy.snapshot().status;
        if (proxy_state == .ready and !self.using_proxy) {
            self.proxy.finishCompletedThread();
            self.prepareThumbnails(self.proxy.path().?, false);
            self.mutex.lock();
            self.using_proxy = true;
            self.proxy_failure_handled = false;
            self.decode_generation +%= 1;
            self.seek_origin_seconds = self.position_seconds;
            self.playback_clock_seconds = self.position_seconds;
            self.resetFrameQueueLocked();
            self.has_displayed_frame = false;
            self.eof = false;
            self.failed = false;
            const start_seconds = self.position_seconds;
            self.pending_decoder_start = start_seconds;
            self.pending_playing = true;
            self.pending_seek_delay_seconds = 0;
            self.playing = false;
            if (self.thread != null) self.cancel_requested = true;
            self.queue_space_available.broadcast();
            self.mutex.unlock();
        } else if (proxy_state == .failed and !self.proxy_failure_handled) {
            self.proxy.finishCompletedThread();
            self.proxy_failure_handled = true;
            // Keep the original path usable if proxy creation fails.
            self.mutex.lock();
            const needs_decoder = self.thread == null;
            self.eof = false;
            self.playing = true;
            const start_seconds = self.position_seconds;
            self.mutex.unlock();
            if (needs_decoder) self.startDecoder(start_seconds) catch {
                self.mutex.lock();
                self.failed = true;
                self.playing = false;
                self.mutex.unlock();
            };
        }
    }

    /// Completes the poster-to-proxy handoff without ever joining an active
    /// decoder on the UI thread. Joining a thread already marked as finished
    /// only releases its OS resources and returns immediately.
    fn continueProxyTransition(self: *Player) void {
        self.mutex.lock();
        const waiting = self.waiting_to_start_proxy;
        const finished = self.decoder_finished;
        self.mutex.unlock();
        if (!waiting or !finished) return;

        if (self.thread) |active| {
            active.join();
            self.thread = null;
        }
        self.mutex.lock();
        self.waiting_to_start_proxy = false;
        self.eof = false;
        self.mutex.unlock();
        self.proxy.start() catch {
            self.proxy_failure_handled = false;
        };
    }

    fn prepareThumbnails(
        self: *Player,
        source_path: []const u8,
        include_source_mtime: bool,
    ) void {
        const cached = self.thumbnails.prepare(
            source_path,
            self.duration_seconds,
            include_source_mtime,
            self.width,
            self.height,
        ) catch |err| {
            std.log.warn("could not prepare preview thumbnails: {s}", .{@errorName(err)});
            self.thumbnails_loaded_or_failed = true;
            return;
        };
        self.thumbnails_loaded_or_failed = false;
        if (!cached) self.thumbnails.start() catch |err| {
            std.log.warn("could not start preview thumbnails: {s}", .{@errorName(err)});
            self.thumbnails_loaded_or_failed = true;
        };
    }

    fn activateThumbnailsIfFinished(self: *Player) void {
        if (self.thumbnails_loaded_or_failed) return;
        switch (self.thumbnails.snapshot()) {
            .ready => {
                self.thumbnails.finishCompletedThread();
                const path = self.thumbnails.path() orelse {
                    self.thumbnails_loaded_or_failed = true;
                    return;
                };
                const path_z = self.allocator.dupeZ(u8, path) catch {
                    self.thumbnails_loaded_or_failed = true;
                    return;
                };
                defer self.allocator.free(path_z);
                self.thumbnail_texture = rl.loadTexture(path_z) catch |err| {
                    std.log.warn("could not load preview thumbnails: {s}", .{@errorName(err)});
                    self.thumbnails_loaded_or_failed = true;
                    return;
                };
                rl.setTextureFilter(self.thumbnail_texture.?, .bilinear);
                self.thumbnails_loaded_or_failed = true;
            },
            .failed => {
                self.thumbnails.finishCompletedThread();
                self.thumbnails_loaded_or_failed = true;
            },
            else => {},
        }
    }

    /// Reaps only a worker that has already finished. Seeks and backend swaps
    /// merely request cancellation; the graphical thread never joins a live
    /// decoder process.
    fn continueDecoderRestart(self: *Player) void {
        self.mutex.lock();
        const pending = self.pending_decoder_start;
        const finished = self.decoder_finished;
        const delay_finished = self.pending_seek_delay_seconds <= 0;
        self.mutex.unlock();
        if (pending == null or !finished or !delay_finished) return;

        if (self.thread) |active| {
            active.join();
            self.thread = null;
        }

        self.mutex.lock();
        const start_seconds = self.pending_decoder_start orelse {
            self.mutex.unlock();
            return;
        };
        const resume_playback = self.pending_playing;
        self.pending_decoder_start = null;
        self.pending_playing = false;
        self.playing = resume_playback;
        self.mutex.unlock();
        self.startDecoder(start_seconds) catch {
            self.mutex.lock();
            self.failed = true;
            self.playing = false;
            self.mutex.unlock();
        };
    }

    fn framePixels(self: *Player, index: usize) []u8 {
        const start = index * self.frame_byte_count;
        return self.frame_storage.?[start .. start + self.frame_byte_count];
    }

    fn resetFrameQueueLocked(self: *Player) void {
        self.queue_read_index = 0;
        self.queue_count = 0;
        self.frame_timings = [_]FrameTiming{.{}} ** frame_queue_capacity;
    }

    fn discardStaleFramesLocked(self: *Player) void {
        const discarded = frame_queue.stalePrefixCount(
            &self.frame_timings,
            self.queue_read_index,
            self.queue_count,
            self.decode_generation,
        );
        if (discarded > 0) {
            self.queue_read_index = (self.queue_read_index + discarded) %
                frame_queue_capacity;
            self.queue_count -= discarded;
            self.dropped_frames +|= discarded;
            self.queue_space_available.broadcast();
        }
    }

    fn advancePendingSeek(self: *Player, elapsed_seconds: f32) void {
        const elapsed = @as(f64, @floatCast(elapsed_seconds));
        if (!std.math.isFinite(elapsed) or elapsed <= 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending_seek_delay_seconds = @max(
            0,
            self.pending_seek_delay_seconds - elapsed,
        );
    }

    /// Returns how many frames should leave the queue this tick. The last one
    /// is uploaded; preceding due frames are intentionally dropped so visual
    /// playback follows the monotonic media clock instead of slowing down.
    fn framesDue(self: *const Player) usize {
        return frame_queue.dueCount(
            &self.frame_timings,
            self.queue_read_index,
            self.queue_count,
            self.playback_clock_seconds,
            self.has_displayed_frame,
            self.playing,
        );
    }
};

fn averageMilliseconds(total_ns: u64, samples: u64) f64 {
    if (samples == 0) return 0;
    return @as(f64, @floatFromInt(total_ns)) /
        @as(f64, @floatFromInt(samples)) /
        @as(f64, sync.ns_per_ms);
}
