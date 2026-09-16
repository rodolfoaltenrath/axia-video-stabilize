const std = @import("std");
const editor_time = @import("../editor/time.zig");
const effect_mod = @import("../effects/effect.zig");
const decoder_mod = @import("decoder.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const session_mod = @import("session.zig");
const types = @import("types.zig");
const warp = @import("warp.zig");

pub const native_enabled =
    decoder_mod.native_enabled and warp.native_enabled;

pub const Frame = struct {
    timing: types.FrameTiming,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: decoder_mod.PixelFormat = .bgra8,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_frame: ?*const fn (?*anyopaque, Frame) bool = null,
    should_cancel: ?*const fn (?*anyopaque) bool = null,

    fn submit(self: Observer, frame: Frame) bool {
        if (self.on_frame) |callback| return callback(self.context, frame);
        return true;
    }

    fn isCancelled(self: Observer) bool {
        if (self.should_cancel) |callback| return callback(self.context);
        return false;
    }
};

pub const Options = struct {
    interpolation: warp.Interpolation = .cubic,
};

pub const RenderError = error{
    BackendNotEnabled,
    Cancelled,
    FrameCountMismatch,
    UnexpectedFrameIndex,
    TimingMismatch,
    VideoDimensionsMismatch,
    PixelFormatMismatch,
    SinkFailed,
    SizeOverflow,
} || decoder_mod.DecoderError || session_mod.SessionError ||
    frame_pipeline.Error || warp.WarpError || std.mem.Allocator.Error;

const CompatibilityPrepared = struct {
    analysis: *const session_mod.Analysis,

    fn stabilizationMatrix(
        raw_context: ?*anyopaque,
        lookup: frame_pipeline.StabilizationLookup,
    ) frame_pipeline.PreparedError!warp.AffineMatrix {
        const self: *CompatibilityPrepared = @ptrCast(@alignCast(raw_context.?));
        const frame_index = lookup.frame_index orelse
            return error.InvalidPreparedEffect;
        if (lookup.width != self.analysis.video_info.source.width or
            lookup.height != self.analysis.video_info.source.height)
        {
            return error.InvalidPreparedEffect;
        }
        return self.analysis.renderMatrix(frame_index) catch
            return error.InvalidPreparedEffect;
    }
};

pub const Renderer = if (native_enabled) NativeRenderer else DisabledRenderer;

const DisabledRenderer = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        analysis: *const session_mod.Analysis,
        observer: Observer,
    ) RenderError!void {
        return runWithOptions(allocator, input_path, analysis, .{}, observer);
    }

    pub fn runWithOptions(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        analysis: *const session_mod.Analysis,
        options: Options,
        observer: Observer,
    ) RenderError!void {
        _ = allocator;
        _ = input_path;
        _ = analysis;
        _ = options;
        _ = observer;
        return error.BackendNotEnabled;
    }
};

const NativeRenderer = struct {
    /// Executes the second decode pass and submits borrowed, stabilized BGRA
    /// frames to a sink. Pixel storage is reused after every callback.
    pub fn run(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        analysis: *const session_mod.Analysis,
        observer: Observer,
    ) RenderError!void {
        return runWithOptions(allocator, input_path, analysis, .{}, observer);
    }

    pub fn runWithOptions(
        allocator: std.mem.Allocator,
        input_path: []const u8,
        analysis: *const session_mod.Analysis,
        options: Options,
        observer: Observer,
    ) RenderError!void {
        if (observer.isCancelled()) return error.Cancelled;
        var decoder = try decoder_mod.Decoder.open(
            allocator,
            input_path,
            .{ .output_format = .bgra8 },
        );
        defer decoder.deinit();
        if (decoder.info.source.width != analysis.video_info.source.width or
            decoder.info.source.height != analysis.video_info.source.height)
        {
            return error.VideoDimensionsMismatch;
        }

        const stride = std.math.mul(
            usize,
            @as(usize, decoder.info.source.width),
            decoder_mod.PixelFormat.bgra8.bytesPerPixel(),
        ) catch return error.SizeOverflow;
        const buffer_size = std.math.mul(
            usize,
            stride,
            @as(usize, decoder.info.source.height),
        ) catch return error.SizeOverflow;
        const output_pixels = try allocator.alloc(u8, buffer_size);
        defer allocator.free(output_pixels);

        var rendered_count: usize = 0;
        const compatibility_effects = [_]effect_mod.Effect{
            .{ .stabilization = .{} },
        };
        var prepared = CompatibilityPrepared{ .analysis = analysis };
        while (try decoder.readFrame()) |frame| {
            if (observer.isCancelled()) return error.Cancelled;
            if (rendered_count >= analysis.records.len) {
                return error.FrameCountMismatch;
            }
            if (frame.timing.index != @as(u64, @intCast(rendered_count))) {
                return error.UnexpectedFrameIndex;
            }
            if (frame.format != .bgra8) return error.PixelFormatMismatch;
            const expected_timing = analysis.records[rendered_count].timing;
            if (frame.timing.pts != expected_timing.pts or
                frame.timing.time_base.numerator !=
                    expected_timing.time_base.numerator or
                frame.timing.time_base.denominator !=
                    expected_timing.time_base.denominator)
            {
                return error.TimingMismatch;
            }
            const source_time = try editor_time.Time.fromUnits(
                frame.timing.pts,
                frame.timing.time_base.numerator,
                frame.timing.time_base.denominator,
            );
            try frame_pipeline.processBgra(
                frame.pixels,
                frame.stride,
                output_pixels,
                stride,
                .{
                    .clip_id = 0,
                    .source_time = source_time,
                    .frame_index = rendered_count,
                    .width = frame.width,
                    .height = frame.height,
                },
                &compatibility_effects,
                .{
                    .context = &prepared,
                    .interpolation = options.interpolation,
                    .stabilization_matrix = CompatibilityPrepared.stabilizationMatrix,
                },
            );
            if (!observer.submit(.{
                .timing = frame.timing,
                .pixels = output_pixels,
                .width = frame.width,
                .height = frame.height,
                .stride = stride,
            })) {
                return error.SinkFailed;
            }
            rendered_count += 1;
        }
        if (rendered_count != analysis.records.len) {
            return error.FrameCountMismatch;
        }
    }
};
