const std = @import("std");
const state_mod = @import("../app_state.zig");
const media = @import("../core/media.zig");
const engine = @import("../engine/engine.zig");

const Job = union(enum) {
    stabilize: state_mod.JobConfig,
};

/// Single background worker for the ordered native video pipeline. A bounded,
/// single-slot queue prevents concurrent exports from competing for decoder
/// and CPU resources.
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.AppState,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?Job = null,
    stopping: bool = false,
    thread: ?std.Thread = null,

    pub fn create(
        allocator: std.mem.Allocator,
        state: *state_mod.AppState,
    ) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .state = state };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn destroy(self: *ThreadPool) void {
        self.state.requestCancel();
        self.mutex.lock();
        self.stopping = true;
        self.condition.signal();
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn submit(self: *ThreadPool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending != null or self.stopping) return false;
        const config = self.state.begin() orelse return false;
        self.pending = .{ .stabilize = config };
        self.condition.signal();
        return true;
    }

    fn workerMain(self: *ThreadPool) void {
        while (true) {
            self.mutex.lock();
            while (self.pending == null and !self.stopping) {
                self.condition.wait(&self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const job = self.pending.?;
            self.pending = null;
            self.mutex.unlock();

            switch (job) {
                .stabilize => |config| self.runPipeline(config),
            }
        }
    }

    fn runPipeline(self: *ThreadPool, config: state_mod.JobConfig) void {
        self.runPipelineFallible(config) catch |err| {
            if (err == error.Cancelled) {
                self.state.update(.cancelled, 0.0);
                self.state.setMessage("Processamento cancelado.");
                return;
            }
            std.log.err(
                "native stabilization pipeline failed: {s}",
                .{@errorName(err)},
            );
            self.state.fail(messageForError(err));
        };
    }

    fn runPipelineFallible(
        self: *ThreadPool,
        config: state_mod.JobConfig,
    ) !void {
        try engine.ensureReady();
        if (config.parameters.mode == .distortion) {
            return error.DistortionModeNotImplemented;
        }

        self.state.update(.loading, 0.02);
        var progress = NativeProgress{ .state = self.state };
        const normalized_smoothness =
            std.math.clamp(config.parameters.smoothness, 0.0, 100.0) / 100.0;
        const crop_fraction =
            std.math.clamp(config.parameters.crop, 0.0, 30.0) / 100.0;
        const encoder_profile = config.parameters.export_quality.encoderProfile();
        var output_buffer: [state_mod.max_path_bytes]u8 = undefined;
        const output_path = try media.deriveAvailableOutputPath(
            &output_buffer,
            config.media.input(),
        );
        if (!self.state.setOutputPath(output_path)) {
            return error.OutputPathTooLong;
        }
        _ = try engine.exporter.Exporter.run(
            self.allocator,
            config.media.input(),
            output_path,
            .{
                .session = .{
                    .smoothing_radius_seconds = normalized_smoothness * normalized_smoothness * 2.0,
                    .crop = .{
                        .mode = if (config.parameters.dynamic_crop)
                            .dynamic
                        else
                            .static,
                        .extra_crop_fraction = crop_fraction,
                    },
                },
                .encoder = .{
                    .crf = encoder_profile.crf,
                    .preset = encoder_profile.preset,
                },
                .observer = .{
                    .context = &progress,
                    .on_progress = NativeProgress.onProgress,
                    .should_cancel = NativeProgress.shouldCancel,
                },
            },
        );
        self.state.complete();
    }
};

fn messageForError(err: anyerror) []const u8 {
    return switch (err) {
        error.DistortionModeNotImplemented => "O modo de distorção ainda não está disponível.",
        error.NativeDependenciesDisabled => "A engine exige FFmpeg e OpenCV no build.",
        error.OpenInputFailed, error.StreamInfoFailed, error.VideoStreamNotFound => "Não foi possível abrir o vídeo selecionado.",
        error.DecoderNotFound => "O FFmpeg não possui o decoder deste vídeo. No Fedora, instale libavcodec-freeworld.",
        error.EncoderNotFound => "Nenhum encoder H.264 compatível foi encontrado no FFmpeg.",
        error.HeaderWriteFailed => "O contêiner MP4 rejeitou um dos streams de vídeo ou áudio.",
        error.TranscoderNotFound => "Instale o FFmpeg para converter o áudio deste vídeo.",
        error.AudioTranscodeFailed => "Não foi possível converter o áudio para AAC.",
        error.NoAvailableOutputName => "Há muitas exportações deste vídeo na pasta de destino.",
        error.OutputPathTooLong => "O caminho do arquivo de saída é longo demais.",
        error.PacketWriteFailed, error.TrailerWriteFailed, error.PublishFailed => "Não foi possível finalizar o MP4 estabilizado.",
        else => "Falha inesperada no pipeline de estabilização.",
    };
}

const NativeProgress = struct {
    state: *state_mod.AppState,
    stage: ?engine.exporter.Stage = null,
    last_sample_ns: i128 = 0,
    last_sample_frames: u64 = 0,
    processing_speed: f64 = 0,

    fn onProgress(
        raw_context: ?*anyopaque,
        progress: engine.exporter.Progress,
    ) void {
        const self: *NativeProgress = @ptrCast(@alignCast(raw_context.?));
        const phase: state_mod.Phase = switch (progress.stage) {
            .analyzing => .analyzing,
            .smoothing => .smoothing,
            .rendering => .rendering,
            .muxing => .muxing,
            .completed => .completed,
        };
        const start: f32 = switch (progress.stage) {
            .analyzing => 0.04,
            .smoothing => 0.68,
            .rendering => 0.70,
            .muxing => 0.96,
            .completed => 1.0,
        };
        const end: f32 = switch (progress.stage) {
            .analyzing => 0.67,
            .smoothing => 0.69,
            .rendering => 0.94,
            .muxing => 0.99,
            .completed => 1.0,
        };
        if (progress.stage == .muxing) {
            const ratio = std.math.clamp(
                progress.stage_progress orelse 0,
                0,
                1,
            );
            self.state.updateStageProgress(
                phase,
                start + (end - start) * ratio,
            );
            return;
        }

        const ratio: f32 = if (progress.total_frames) |estimated|
            @floatCast(@as(f64, @floatFromInt(progress.processed_frames)) /
                @as(f64, @floatFromInt(@max(estimated, 1))))
        else
            0;
        const speed = self.measureSpeed(progress);
        self.state.updateFrameProgress(
            phase,
            start + (end - start) * std.math.clamp(ratio, 0.0, 1.0),
            progress.processed_frames,
            progress.total_frames,
            speed,
        );
    }

    fn measureSpeed(
        self: *NativeProgress,
        progress: engine.exporter.Progress,
    ) f64 {
        const measures_frames = switch (progress.stage) {
            .analyzing, .rendering => true,
            .smoothing, .muxing, .completed => false,
        };
        if (!measures_frames) {
            self.stage = progress.stage;
            self.last_sample_ns = 0;
            self.last_sample_frames = progress.processed_frames;
            self.processing_speed = 0;
            return 0;
        }

        const now = std.time.nanoTimestamp();
        if (self.stage == null or self.stage.? != progress.stage or
            self.last_sample_ns == 0)
        {
            self.stage = progress.stage;
            self.last_sample_ns = now;
            self.last_sample_frames = progress.processed_frames;
            self.processing_speed = 0;
            return 0;
        }

        const elapsed_ns = now - self.last_sample_ns;
        if (elapsed_ns < 250 * std.time.ns_per_ms or
            progress.processed_frames < self.last_sample_frames)
        {
            return self.processing_speed;
        }

        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) /
            @as(f64, std.time.ns_per_s);
        const frame_delta = progress.processed_frames -
            self.last_sample_frames;
        const sample = @as(f64, @floatFromInt(frame_delta)) /
            elapsed_seconds;
        self.processing_speed = if (self.processing_speed == 0)
            sample
        else
            self.processing_speed * 0.75 + sample * 0.25;
        self.last_sample_ns = now;
        self.last_sample_frames = progress.processed_frames;
        return self.processing_speed;
    }

    fn shouldCancel(raw_context: ?*anyopaque) bool {
        const self: *NativeProgress = @ptrCast(@alignCast(raw_context.?));
        return self.state.shouldCancel();
    }
};
