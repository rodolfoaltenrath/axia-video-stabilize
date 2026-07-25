const std = @import("std");
const state_mod = @import("../app_state.zig");
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
        _ = try engine.exporter.Exporter.run(
            self.allocator,
            config.media.input(),
            config.media.output(),
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
        error.EncoderNotFound => "Nenhum encoder H.264 compatível foi encontrado no FFmpeg.",
        error.HeaderWriteFailed => "O contêiner MP4 rejeitou um dos streams de vídeo ou áudio.",
        error.PacketWriteFailed, error.TrailerWriteFailed, error.PublishFailed => "Não foi possível finalizar o MP4 estabilizado.",
        else => "Falha inesperada no pipeline de estabilização.",
    };
}

const NativeProgress = struct {
    state: *state_mod.AppState,

    fn onProgress(
        raw_context: ?*anyopaque,
        progress: engine.exporter.Progress,
    ) void {
        const self: *NativeProgress = @ptrCast(@alignCast(raw_context.?));
        const total = progress.total_frames orelse
            @max(progress.processed_frames, 1);
        const ratio: f32 =
            @floatCast(@as(f64, @floatFromInt(progress.processed_frames)) /
            @as(f64, @floatFromInt(total)));
        const phase: state_mod.Phase = switch (progress.stage) {
            .analyzing => .analyzing,
            .rendering, .muxing, .completed => .rendering,
        };
        const start: f32 = switch (progress.stage) {
            .analyzing => 0.04,
            .rendering => 0.70,
            .muxing => 0.96,
            .completed => 1.0,
        };
        const end: f32 = switch (progress.stage) {
            .analyzing => 0.67,
            .rendering => 0.94,
            .muxing => 0.99,
            .completed => 1.0,
        };
        self.state.updateFrameProgress(
            phase,
            start + (end - start) * std.math.clamp(ratio, 0.0, 1.0),
            progress.processed_frames,
            total,
            0,
        );
    }

    fn shouldCancel(raw_context: ?*anyopaque) bool {
        const self: *NativeProgress = @ptrCast(@alignCast(raw_context.?));
        return self.state.shouldCancel();
    }
};
