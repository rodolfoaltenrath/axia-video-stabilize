const std = @import("std");
const build_options = @import("build_options");

/// The C headers are parsed only in builds that explicitly enable the native
/// backend. Keeping the import here makes FFmpeg types available without
/// leaking C declarations through the rest of the application.
pub const ffmpeg = if (build_options.native_video) @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
}) else struct {};

pub const VideoError = error{
    BackendNotEnabled,
    OpenInputFailed,
    StreamNotFound,
    DecoderNotFound,
    DecodeFailed,
    EncodeFailed,
};

pub const Rational = struct { numerator: i32, denominator: i32 };

pub const VideoInfo = struct {
    width: u32,
    height: u32,
    frame_rate: Rational,
    duration_seconds: f64,
    frame_count: ?u64,
};

pub const PixelFormat = enum { rgba, gray8 };

pub const Frame = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    pts: i64,
    format: PixelFormat,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Owns AVFormatContext, AVCodecContext, AVFrame, AVPacket and SwsContext in
/// the native implementation. All allocations that cross the C boundary are
/// released from deinit, while output pixel buffers use the Zig allocator.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    info: VideoInfo,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) VideoError!Decoder {
        _ = path;
        if (!build_options.native_video) return error.BackendNotEnabled;

        // FFmpeg hook point:
        // 1. avformat_open_input + avformat_find_stream_info
        // 2. av_find_best_stream(AVMEDIA_TYPE_VIDEO)
        // 3. avcodec_alloc_context3 + avcodec_open2
        // 4. sws_getContext for RGBA and gray8 preview/optical-flow frames
        return .{
            .allocator = allocator,
            .info = .{
                .width = 0,
                .height = 0,
                .frame_rate = .{ .numerator = 0, .denominator = 1 },
                .duration_seconds = 0,
                .frame_count = null,
            },
        };
    }

    pub fn deinit(self: *Decoder) void {
        // Release in reverse ownership order: SwsContext, AVPacket, AVFrame,
        // AVCodecContext and finally AVFormatContext.
        self.* = undefined;
    }

    pub fn readFrame(self: *Decoder, format: PixelFormat) VideoError!?Frame {
        _ = self;
        _ = format;
        // Loop av_read_frame, send packets to avcodec_send_packet and receive
        // frames with avcodec_receive_frame. Convert through sws_scale.
        return null;
    }

    pub fn seek(self: *Decoder, seconds: f64) VideoError!void {
        _ = self;
        _ = seconds;
        // avformat_seek_file followed by avcodec_flush_buffers.
    }
};

/// Encoder hook: create an output format context, select a codec, copy timing
/// metadata, feed warped frames and flush both codec and muxer on finish.
pub const Encoder = struct {
    pub fn create(path: []const u8, info: VideoInfo) VideoError!Encoder {
        _ = path;
        _ = info;
        if (!build_options.native_video) return error.BackendNotEnabled;
        return .{};
    }

    pub fn deinit(self: *Encoder) void {
        self.* = undefined;
    }

    pub fn writeFrame(self: *Encoder, frame: *const Frame) VideoError!void {
        _ = self;
        _ = frame;
    }
};
