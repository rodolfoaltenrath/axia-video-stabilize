const std = @import("std");
const encoder_mod = @import("encoder.zig");
const muxer = @import("muxer.zig");
const renderer = @import("renderer.zig");
const session_mod = @import("session.zig");

pub const native_enabled =
    session_mod.native_enabled and encoder_mod.native_enabled and
    muxer.native_enabled and renderer.native_enabled;

pub const Stage = enum {
    analyzing,
    rendering,
    muxing,
    completed,
};

pub const Progress = struct {
    stage: Stage,
    processed_frames: u64 = 0,
    total_frames: ?u64 = null,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_progress: ?*const fn (?*anyopaque, Progress) void = null,
    should_cancel: ?*const fn (?*anyopaque) bool = null,

    fn report(self: Observer, progress: Progress) void {
        if (self.on_progress) |callback| callback(self.context, progress);
    }

    fn isCancelled(self: Observer) bool {
        if (self.should_cancel) |callback| return callback(self.context);
        return false;
    }
};

pub const Options = struct {
    session: session_mod.Options = .{},
    encoder: encoder_mod.Options = .{},
    muxer: muxer.Options = .{},
    observer: Observer = .{},
};

pub const Result = struct {
    frames: u64,
    audio_streams: u32,
};

pub const ExportError = error{
    BackendNotEnabled,
    Cancelled,
    InputEqualsOutput,
    EmptyAnalysis,
    PublishFailed,
} || session_mod.SessionError || renderer.RenderError ||
    encoder_mod.EncoderError || muxer.MuxError ||
    std.mem.Allocator.Error;

pub const Exporter = if (native_enabled) NativeExporter else DisabledExporter;

const DisabledExporter = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        output_path: []const u8,
        options: Options,
    ) ExportError!Result {
        _ = allocator;
        _ = input_path;
        _ = output_path;
        _ = options;
        return error.BackendNotEnabled;
    }
};

const NativeExporter = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        output_path: []const u8,
        options: Options,
    ) ExportError!Result {
        if (std.mem.eql(u8, input_path, output_path)) {
            return error.InputEqualsOutput;
        }
        if (options.observer.isCancelled()) return error.Cancelled;

        const video_temp_path = try std.fmt.allocPrint(
            allocator,
            "{s}.axia-video.mp4",
            .{output_path},
        );
        defer allocator.free(video_temp_path);
        const partial_path = try std.fmt.allocPrint(
            allocator,
            "{s}.axia-partial.mp4",
            .{output_path},
        );
        defer allocator.free(partial_path);
        deleteFile(video_temp_path);
        deleteFile(partial_path);
        defer deleteFile(video_temp_path);
        var published = false;
        defer if (!published) deleteFile(partial_path);

        var analysis_observer = AnalysisObserver{
            .observer = options.observer,
        };
        var session_options = options.session;
        session_options.observer = .{
            .context = &analysis_observer,
            .on_progress = AnalysisObserver.onProgress,
            .should_cancel = AnalysisObserver.shouldCancel,
        };
        var analysis = try session_mod.Session.run(
            allocator,
            input_path,
            session_options,
        );
        defer analysis.deinit();
        if (analysis.records.len == 0) return error.EmptyAnalysis;

        var encoder = try encoder_mod.Encoder.create(
            allocator,
            video_temp_path,
            analysis.video_info.source,
            analysis.video_info.time_base,
            analysis.video_info.frame_rate,
            options.encoder,
        );
        var encoder_open = true;
        defer if (encoder_open) encoder.deinit();
        var sink = EncoderSink{
            .encoder = &encoder,
            .observer = options.observer,
            .total_frames = @intCast(analysis.records.len),
        };
        renderer.Renderer.run(
            allocator,
            input_path,
            &analysis,
            .{
                .context = &sink,
                .on_frame = EncoderSink.onFrame,
                .should_cancel = EncoderSink.shouldCancel,
            },
        ) catch |err| {
            if (err == error.SinkFailed) {
                if (sink.encoder_error) |encoder_error| {
                    return encoder_error;
                }
            }
            return err;
        };
        try encoder.finish();
        
        // Close AVIO before reopening the intermediate file for remuxing.
        encoder.deinit();
        encoder_open = false;

        if (options.observer.isCancelled()) return error.Cancelled;
        options.observer.report(.{
            .stage = .muxing,
            .processed_frames = @intCast(analysis.records.len),
            .total_frames = @intCast(analysis.records.len),
        });
        const mux_result = try muxer.Muxer.run(
            allocator,
            video_temp_path,
            input_path,
            partial_path,
            options.muxer,
        );
        if (options.observer.isCancelled()) return error.Cancelled;
        
        // A publicação final vai garantir que não haja conflitos de nome
        publishFile(partial_path, output_path) catch
            return error.PublishFailed;
        published = true;

        const frame_count: u64 = @intCast(analysis.records.len);
        options.observer.report(.{
            .stage = .completed,
            .processed_frames = frame_count,
            .total_frames = frame_count,
        });
        return .{
            .frames = frame_count,
            .audio_streams = mux_result.audio_streams,
        };
    }
};

const AnalysisObserver = struct {
    observer: Observer,

    fn onProgress(
        raw_context: ?*anyopaque,
        progress: session_mod.Progress,
    ) void {
        const self: *AnalysisObserver =
            @ptrCast(@alignCast(raw_context.?));
        self.observer.report(.{
            .stage = .analyzing,
            .processed_frames = progress.decoded_frames,
            .total_frames = progress.estimated_frames,
        });
    }

    fn shouldCancel(raw_context: ?*anyopaque) bool {
        const self: *AnalysisObserver =
            @ptrCast(@alignCast(raw_context.?));
        return self.observer.isCancelled();
    }
};

const EncoderSink = struct {
    encoder: *encoder_mod.Encoder,
    observer: Observer,
    total_frames: u64,
    encoded_frames: u64 = 0,
    encoder_error: ?encoder_mod.EncoderError = null,

    fn onFrame(
        raw_context: ?*anyopaque,
        frame: renderer.Frame,
    ) bool {
        const self: *EncoderSink = @ptrCast(@alignCast(raw_context.?));
        self.encoder.writeFrame(frame) catch |err| {
            self.encoder_error = err;
            return false;
        };
        self.encoded_frames += 1;
        self.observer.report(.{
            .stage = .rendering,
            .processed_frames = self.encoded_frames,
            .total_frames = self.total_frames,
        });
        return true;
    }

    fn shouldCancel(raw_context: ?*anyopaque) bool {
        const self: *EncoderSink = @ptrCast(@alignCast(raw_context.?));
        return self.observer.isCancelled();
    }
};

fn deleteFile(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn publishFile(source: []const u8, destination: []const u8) !void {
    // -------------------------------------------------------------
    // FIX: O Windows recusa sobrescrever arquivos com rename. 
    // Precisamos apagar o destino caso ele exista.
    // -------------------------------------------------------------
    deleteFile(destination);

    if (std.fs.path.isAbsolute(source) and
        std.fs.path.isAbsolute(destination))
    {
        try std.fs.renameAbsolute(source, destination);
    } else {
        try std.fs.cwd().rename(source, destination);
    }
}