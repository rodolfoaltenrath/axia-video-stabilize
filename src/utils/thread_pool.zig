const std = @import("std");
const state_mod = @import("../app_state.zig");
const ffmpeg_cli = @import("../core/ffmpeg_cli.zig");

const Job = union(enum) {
    stabilize: state_mod.JobConfig,
};

/// Single background worker for the ordered video pipeline. A bounded, single
/// slot queue is intentional: two exports must never compete for decoder/GPU
/// resources.
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.AppState,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?Job = null,
    stopping: bool = false,
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, state: *state_mod.AppState) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .state = state };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn destroy(self: *ThreadPool) void {
        // The CLI backend currently observes cancellation between FFmpeg passes.
        // Mid-pass process termination is implemented in the next milestone.
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
            while (self.pending == null and !self.stopping) self.condition.wait(&self.mutex);
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
            std.log.err("stabilization pipeline failed: {s}", .{@errorName(err)});
            self.state.fail(messageForError(err));
        };
    }

    fn runPipelineFallible(self: *ThreadPool, config: state_mod.JobConfig) !void {
        if (config.parameters.mode == .distortion) return error.DistortionModeNotImplemented;

        self.state.update(.loading, 0.02);
        const info = try ffmpeg_cli.probe(self.allocator, config.media.input());
        self.state.update(.loading, 0.08);
        if (self.finishIfCancelled()) return;

        const temp_directory = try getTempDirectory(self.allocator);
        defer self.allocator.free(temp_directory);
        const transform_name = try std.fmt.allocPrint(
            self.allocator,
            "axia-{d}.trf",
            .{std.time.nanoTimestamp()},
        );
        defer self.allocator.free(transform_name);
        const transform_path = try std.fs.path.join(self.allocator, &.{ temp_directory, transform_name });
        defer self.allocator.free(transform_path);
        defer std.fs.deleteFileAbsolute(transform_path) catch {};

        self.state.update(.analyzing, 0.10);
        try ffmpeg_cli.analyze(
            self.allocator,
            config.media.input(),
            temp_directory,
            transform_name,
        );
        self.state.update(.analyzing, 0.67);
        if (self.finishIfCancelled()) return;

        self.state.update(.smoothing, 0.72);
        self.state.update(.rendering, 0.74);
        try ffmpeg_cli.render(
            self.allocator,
            config.media.input(),
            config.media.output(),
            temp_directory,
            transform_name,
            config.parameters,
            info,
        );
        if (self.finishIfCancelled()) {
            std.fs.deleteFileAbsolute(config.media.output()) catch {};
            return;
        }
        self.state.complete();
    }

    fn finishIfCancelled(self: *ThreadPool) bool {
        if (!self.state.shouldCancel()) return false;
        self.state.update(.cancelled, 0.0);
        self.state.setMessage("Processamento cancelado.");
        return true;
    }
};

fn getTempDirectory(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "TEMP") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "TMP"),
        else => return err,
    };
}

fn messageForError(err: anyerror) []const u8 {
    return switch (err) {
        error.ToolNotFound => "FFmpeg/ffprobe não encontrado. Verifique o PATH ou AXIA_FFMPEG.",
        error.ProbeFailed, error.InvalidProbeOutput, error.InvalidFrameRate => "Não foi possível ler os metadados do vídeo.",
        error.AnalyzeFailed => "A análise de movimento falhou. Consulte o log para detalhes.",
        error.RenderFailed => "A renderização falhou. Consulte o log para detalhes.",
        error.DistortionModeNotImplemented => "O modo de distorção ainda não está disponível.",
        else => "Falha inesperada no pipeline de estabilização.",
    };
}
