const std = @import("std");

pub const Phase = enum {
    idle,
    loading,
    analyzing,
    smoothing,
    rendering,
    muxing,
    completed,
    failed,
    cancelled,

    pub fn label(self: Phase) [:0]const u8 {
        return switch (self) {
            .idle => "Pronto",
            .loading => "Carregando vídeo",
            .analyzing => "Analisando movimento",
            .smoothing => "Suavizando trajetória",
            .rendering => "Renderizando vídeo",
            .muxing => "Finalizando áudio e contêiner",
            .completed => "Exportação concluída",
            .failed => "Falha no processamento",
            .cancelled => "Operação cancelada",
        };
    }

    pub fn isBusy(self: Phase) bool {
        return switch (self) {
            .loading, .analyzing, .smoothing, .rendering, .muxing => true,
            else => false,
        };
    }
};

pub const StabilizationMode = enum {
    motion,
    distortion,
};

pub const ExportQuality = enum {
    high,
    balanced,
    compact,

    pub const EncoderProfile = struct {
        crf: u8,
        preset: []const u8,
    };

    pub fn encoderProfile(self: ExportQuality) EncoderProfile {
        return switch (self) {
            .high => .{ .crf = 16, .preset = "slow" },
            .balanced => .{ .crf = 18, .preset = "medium" },
            .compact => .{ .crf = 24, .preset = "fast" },
        };
    }
};

pub const Parameters = struct {
    smoothness: f32 = 72.0,
    crop: f32 = 12.0,
    dynamic_crop: bool = true,
    mode: StabilizationMode = .motion,
    export_quality: ExportQuality = .balanced,
};

pub const max_path_bytes = 2048;
pub const max_name_bytes = 256;
pub const max_message_bytes = 384;

pub const MediaSelection = struct {
    input_path: [max_path_bytes:0]u8 = [_:0]u8{0} ** max_path_bytes,
    input_len: usize = 0,
    output_path: [max_path_bytes:0]u8 = [_:0]u8{0} ** max_path_bytes,
    output_len: usize = 0,
    display_name: [max_name_bytes:0]u8 = [_:0]u8{0} ** max_name_bytes,
    display_name_len: usize = 0,

    pub fn hasInput(self: *const MediaSelection) bool {
        return self.input_len > 0;
    }

    pub fn input(self: *const MediaSelection) [:0]const u8 {
        return self.input_path[0..self.input_len :0];
    }

    pub fn output(self: *const MediaSelection) [:0]const u8 {
        return self.output_path[0..self.output_len :0];
    }

    pub fn name(self: *const MediaSelection) [:0]const u8 {
        return self.display_name[0..self.display_name_len :0];
    }
};

pub const JobConfig = struct {
    parameters: Parameters,
    media: MediaSelection,
};

pub const Snapshot = struct {
    phase: Phase,
    progress: f32,
    parameters: Parameters,
    cancel_requested: bool,
    media: MediaSelection,
    message: [max_message_bytes:0]u8,
    message_len: usize,
    processed_frame: u64,
    total_frames: ?u64,
    processing_speed: f32,

    pub fn status(self: *const Snapshot) [:0]const u8 {
        if (self.message_len > 0) return self.message[0..self.message_len :0];
        return self.phase.label();
    }
};

pub const AppState = struct {
    mutex: std.Thread.Mutex = .{},
    phase: Phase = .idle,
    progress: f32 = 0.0,
    parameters: Parameters = .{},
    cancel_requested: bool = false,
    media: MediaSelection = .{},
    message: [max_message_bytes:0]u8 = [_:0]u8{0} ** max_message_bytes,
    message_len: usize = 0,
    processed_frame: u64 = 0,
    total_frames: ?u64 = null,
    processing_speed: f32 = 0,

    pub fn snapshot(self: *AppState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .phase = self.phase,
            .progress = self.progress,
            .parameters = self.parameters,
            .cancel_requested = self.cancel_requested,
            .media = self.media,
            .message = self.message,
            .message_len = self.message_len,
            .processed_frame = self.processed_frame,
            .total_frames = self.total_frames,
            .processing_speed = self.processing_speed,
        };
    }

    pub fn setParameters(self: *AppState, parameters: Parameters) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.parameters = parameters;
    }

    pub fn setMedia(self: *AppState, input_path: []const u8, output_path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase.isBusy()) return false;
        if (input_path.len == 0 or input_path.len > max_path_bytes or output_path.len > max_path_bytes) return false;

        self.media = .{};
        @memcpy(self.media.input_path[0..input_path.len], input_path);
        self.media.input_len = input_path.len;
        @memcpy(self.media.output_path[0..output_path.len], output_path);
        self.media.output_len = output_path.len;
        const name = std.fs.path.basename(input_path);
        const name_len = @min(name.len, max_name_bytes);
        @memcpy(self.media.display_name[0..name_len], name[0..name_len]);
        self.media.display_name_len = name_len;
        self.phase = .idle;
        self.progress = 0.0;
        self.cancel_requested = false;
        self.processed_frame = 0;
        self.total_frames = null;
        self.processing_speed = 0;
        self.setMessageLocked("Mídia carregada. Ajuste os parâmetros e inicie a análise.");
        return true;
    }

    pub fn setMessage(self: *AppState, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.setMessageLocked(message);
    }

    pub fn begin(self: *AppState) ?JobConfig {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase.isBusy() or !self.media.hasInput()) return null;
        self.phase = .loading;
        self.progress = 0.0;
        self.cancel_requested = false;
        self.processed_frame = 0;
        self.total_frames = null;
        self.processing_speed = 0;
        self.setMessageLocked("");
        return .{ .parameters = self.parameters, .media = self.media };
    }

    pub fn update(self: *AppState, phase: Phase, progress: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.phase = phase;
        self.progress = std.math.clamp(progress, 0.0, 1.0);
        if (phase.isBusy()) self.setMessageLocked("");
    }

    pub fn updateFrameProgress(
        self: *AppState,
        phase: Phase,
        progress: f32,
        processed_frame: u64,
        total_frames: ?u64,
        processing_speed: f64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.phase = phase;
        self.progress = std.math.clamp(progress, 0.0, 1.0);
        self.processed_frame = if (total_frames) |total|
            @min(processed_frame, total)
        else
            processed_frame;
        self.total_frames = total_frames;
        self.processing_speed = @floatCast(@max(0.0, processing_speed));
        self.setMessageLocked("");
    }

    pub fn updateStageProgress(
        self: *AppState,
        phase: Phase,
        progress: f32,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.phase = phase;
        self.progress = std.math.clamp(progress, 0.0, 1.0);
        self.processed_frame = 0;
        self.total_frames = null;
        self.processing_speed = 0;
        if (phase.isBusy()) self.setMessageLocked("");
    }

    pub fn fail(self: *AppState, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.phase = .failed;
        self.setMessageLocked(message);
    }

    pub fn complete(self: *AppState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.phase = .completed;
        self.progress = 1.0;
        self.setMessageLocked("Exportação concluída. O MP4 foi salvo ao lado do original.");
    }

    pub fn requestCancel(self: *AppState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase.isBusy()) self.cancel_requested = true;
    }

    pub fn shouldCancel(self: *AppState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn setMessageLocked(self: *AppState, message: []const u8) void {
        self.message = [_:0]u8{0} ** max_message_bytes;
        const length = @min(message.len, max_message_bytes);
        @memcpy(self.message[0..length], message[0..length]);
        self.message_len = length;
    }
};
