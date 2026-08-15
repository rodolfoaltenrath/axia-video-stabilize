const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");

const ffmpeg = if (build_options.native_ffmpeg) @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/display.h");
    @cInclude("libavutil/pixdesc.h");
    @cInclude("libswscale/swscale.h");
}) else struct {};

pub const native_enabled = build_options.native_ffmpeg;

pub const DecoderError = error{
    BackendNotEnabled,
    EmptyPath,
    OpenInputFailed,
    StreamInfoFailed,
    VideoStreamNotFound,
    DecoderNotFound,
    DecoderOpenFailed,
    InvalidVideoDimensions,
    InvalidTimeBase,
    AllocationFailed,
    DecodeFailed,
    MissingTimestamp,
    UnsupportedResolutionChange,
    UnsupportedHdrTransfer,
    ConversionFailed,
} || std.mem.Allocator.Error;

pub const Options = struct {
    max_analysis_dimension: u32 = 960,
    output_format: PixelFormat = .gray8,
};

pub const PixelFormat = enum {
    gray8,
    /// BGRA scaled to `VideoInfo.analysis` for color-aware analysis.
    bgra8_analysis,
    /// Full-resolution BGRA used by the renderer and encoder.
    bgra8,

    pub fn bytesPerPixel(self: PixelFormat) usize {
        return switch (self) {
            .gray8 => 1,
            .bgra8_analysis, .bgra8 => 4,
        };
    }
};

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

/// Raw H.273/FFmpeg color identifiers. Keeping the numeric identifiers allows
/// uncommon primaries and transfer functions to survive the native pipeline
/// without narrowing them to a small application-specific enum.
pub const ColorInfo = struct {
    range: i32 = 0,
    primaries: i32 = 2,
    transfer: i32 = 2,
    matrix: i32 = 2,
    chroma_location: i32 = 0,

    pub fn isValid(self: ColorInfo) bool {
        return self.range >= 0 and
            self.primaries >= 0 and
            self.transfer >= 0 and
            self.matrix >= 0 and
            self.chroma_location >= 0;
    }
};

pub const VideoInfo = struct {
    source: Dimensions,
    analysis: Dimensions,
    display_rotation_degrees: f64 = 0,
    color: ColorInfo,
    time_base: types.Rational,
    frame_rate: ?types.Rational,
    duration_seconds: ?f64,
    estimated_frame_count: ?u64,

    pub fn framesPerSecond(self: VideoInfo) ?f64 {
        const rate = self.frame_rate orelse return null;
        return @as(f64, @floatFromInt(rate.numerator)) /
            @as(f64, @floatFromInt(rate.denominator));
    }

    pub fn displayDimensions(self: VideoInfo) Dimensions {
        return orientedDimensions(self.source, self.display_rotation_degrees);
    }
};

pub fn orientedDimensions(
    source: Dimensions,
    rotation_degrees: f64,
) Dimensions {
    if (!std.math.isFinite(rotation_degrees)) return source;
    const quarter_turns: i32 = @intFromFloat(@round(rotation_degrees / 90));
    if (@abs(quarter_turns) % 2 == 0) return source;
    return .{ .width = source.height, .height = source.width };
}

/// Borrowed frame view. Pixel memory remains owned by `Decoder` and is valid
/// only until the next `readFrame` call or `deinit`.
pub const FrameView = struct {
    timing: types.FrameTiming,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: PixelFormat,
};

pub fn fitAnalysisDimensions(
    source_width: u32,
    source_height: u32,
    max_dimension: u32,
) DecoderError!Dimensions {
    if (source_width == 0 or source_height == 0 or max_dimension == 0) {
        return error.InvalidVideoDimensions;
    }

    const largest = @max(source_width, source_height);
    if (largest <= max_dimension) {
        return .{ .width = source_width, .height = source_height };
    }

    if (source_width >= source_height) {
        const scaled_height = @max(
            1,
            (@as(u64, source_height) * max_dimension + source_width / 2) /
                source_width,
        );
        return .{
            .width = max_dimension,
            .height = @intCast(scaled_height),
        };
    }

    const scaled_width = @max(
        1,
        (@as(u64, source_width) * max_dimension + source_height / 2) /
            source_height,
    );
    return .{
        .width = @intCast(scaled_width),
        .height = max_dimension,
    };
}

pub const Decoder = if (build_options.native_ffmpeg) NativeDecoder else DisabledDecoder;

const DisabledDecoder = struct {
    info: VideoInfo = undefined,

    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) DecoderError!DisabledDecoder {
        _ = allocator;
        _ = path;
        _ = options;
        return error.BackendNotEnabled;
    }

    pub fn deinit(self: *DisabledDecoder) void {
        self.* = undefined;
    }

    pub fn readFrame(self: *DisabledDecoder) DecoderError!?FrameView {
        _ = self;
        return error.BackendNotEnabled;
    }
};

const NativeDecoder = struct {
    allocator: std.mem.Allocator,
    format_context: *ffmpeg.AVFormatContext,
    codec_context: *ffmpeg.AVCodecContext,
    frame: *ffmpeg.AVFrame,
    packet: *ffmpeg.AVPacket,
    sws_context: ?*ffmpeg.SwsContext = null,
    video_stream_index: c_int,
    info: VideoInfo,
    output_dimensions: Dimensions,
    output_format: PixelFormat,
    output_pixels: []u8,
    output_frame_size: usize,
    output_stride: usize,
    next_index: u64 = 0,
    draining: bool = false,
    finished: bool = false,

    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Options,
    ) DecoderError!NativeDecoder {
        if (path.len == 0) return error.EmptyPath;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var format_context_optional: ?*ffmpeg.AVFormatContext = null;
        if (ffmpeg.avformat_open_input(
            &format_context_optional,
            path_z.ptr,
            null,
            null,
        ) < 0) {
            return error.OpenInputFailed;
        }
        const format_context = format_context_optional orelse
            return error.OpenInputFailed;
        errdefer {
            var context: ?*ffmpeg.AVFormatContext = format_context;
            ffmpeg.avformat_close_input(&context);
        }

        if (ffmpeg.avformat_find_stream_info(format_context, null) < 0) {
            return error.StreamInfoFailed;
        }

        var codec: ?*const ffmpeg.AVCodec = null;
        const stream_index = ffmpeg.av_find_best_stream(
            format_context,
            ffmpeg.AVMEDIA_TYPE_VIDEO,
            -1,
            -1,
            &codec,
            0,
        );
        if (stream_index < 0) return error.VideoStreamNotFound;
        const selected_codec = codec orelse return error.DecoderNotFound;

        var codec_context_optional: ?*ffmpeg.AVCodecContext =
            ffmpeg.avcodec_alloc_context3(selected_codec);
        const codec_context = codec_context_optional orelse
            return error.AllocationFailed;
        errdefer ffmpeg.avcodec_free_context(&codec_context_optional);

        const stream = format_context.streams[@intCast(stream_index)];
        if (ffmpeg.avcodec_parameters_to_context(
            codec_context,
            stream.*.codecpar,
        ) < 0) {
            return error.DecoderOpenFailed;
        }
        if (ffmpeg.avcodec_open2(codec_context, selected_codec, null) < 0) {
            return error.DecoderOpenFailed;
        }
        if (codec_context.width <= 0 or codec_context.height <= 0) {
            return error.InvalidVideoDimensions;
        }

        const time_base = types.Rational{
            .numerator = stream.*.time_base.num,
            .denominator = stream.*.time_base.den,
        };
        time_base.validate() catch return error.InvalidTimeBase;

        const source = Dimensions{
            .width = @intCast(codec_context.width),
            .height = @intCast(codec_context.height),
        };
        const display_rotation_degrees = streamDisplayRotation(stream);
        const analysis = try fitAnalysisDimensions(
            source.width,
            source.height,
            options.max_analysis_dimension,
        );
        const output_dimensions = switch (options.output_format) {
            .gray8, .bgra8_analysis => analysis,
            .bgra8 => source,
        };
        const output_stride = std.math.mul(
            usize,
            @as(usize, output_dimensions.width),
            options.output_format.bytesPerPixel(),
        ) catch return error.InvalidVideoDimensions;
        const output_size = std.math.mul(
            usize,
            output_stride,
            @as(usize, output_dimensions.height),
        ) catch return error.InvalidVideoDimensions;
        // FFmpeg's optimized pixel converters may touch SIMD padding past the
        // visible image. Keep that padding inside the allocation while exposing
        // only the actual frame bytes through FrameView.
        const output_allocation_size = std.math.add(
            usize,
            output_size,
            @as(usize, ffmpeg.AV_INPUT_BUFFER_PADDING_SIZE),
        ) catch return error.InvalidVideoDimensions;
        const output_pixels = try allocator.alloc(u8, output_allocation_size);
        errdefer allocator.free(output_pixels);
        @memset(output_pixels[output_size..], 0);

        const frame = ffmpeg.av_frame_alloc() orelse
            return error.AllocationFailed;
        errdefer {
            var value: ?*ffmpeg.AVFrame = frame;
            ffmpeg.av_frame_free(&value);
        }

        const packet = ffmpeg.av_packet_alloc() orelse
            return error.AllocationFailed;
        errdefer {
            var value: ?*ffmpeg.AVPacket = packet;
            ffmpeg.av_packet_free(&value);
        }

        const estimated_frame_count: ?u64 = if (stream.*.nb_frames > 0)
            @intCast(stream.*.nb_frames)
        else
            null;
        const guessed_rate = ffmpeg.av_guess_frame_rate(
            format_context,
            stream,
            null,
        );
        const frame_rate: ?types.Rational =
            if (guessed_rate.num > 0 and guessed_rate.den > 0)
            .{
                .numerator = guessed_rate.num,
                .denominator = guessed_rate.den,
            }
        else
            null;
        const duration_seconds: ?f64 =
            if (stream.*.duration != ffmpeg.AV_NOPTS_VALUE and
            stream.*.duration > 0)
            @as(f64, @floatFromInt(stream.*.duration)) *
                @as(f64, @floatFromInt(stream.*.time_base.num)) /
                @as(f64, @floatFromInt(stream.*.time_base.den))
        else if (format_context.duration != ffmpeg.AV_NOPTS_VALUE and
            format_context.duration > 0)
            @as(f64, @floatFromInt(format_context.duration)) /
                @as(f64, ffmpeg.AV_TIME_BASE)
        else
            null;

        return .{
            .allocator = allocator,
            .format_context = format_context,
            .codec_context = codec_context,
            .frame = frame,
            .packet = packet,
            .video_stream_index = stream_index,
            .info = .{
                .source = source,
                .analysis = analysis,
                .display_rotation_degrees = display_rotation_degrees,
                .color = .{
                    .range = @intCast(codec_context.color_range),
                    .primaries = @intCast(codec_context.color_primaries),
                    .transfer = @intCast(codec_context.color_trc),
                    .matrix = @intCast(codec_context.colorspace),
                    .chroma_location = @intCast(
                        codec_context.chroma_sample_location,
                    ),
                },
                .time_base = time_base,
                .frame_rate = frame_rate,
                .duration_seconds = duration_seconds,
                .estimated_frame_count = estimated_frame_count,
            },
            .output_dimensions = output_dimensions,
            .output_format = options.output_format,
            .output_pixels = output_pixels,
            .output_frame_size = output_size,
            .output_stride = output_stride,
        };
    }

    pub fn deinit(self: *NativeDecoder) void {
        if (self.sws_context) |context| ffmpeg.sws_freeContext(context);

        var packet: ?*ffmpeg.AVPacket = self.packet;
        ffmpeg.av_packet_free(&packet);
        var frame: ?*ffmpeg.AVFrame = self.frame;
        ffmpeg.av_frame_free(&frame);
        var codec_context: ?*ffmpeg.AVCodecContext = self.codec_context;
        ffmpeg.avcodec_free_context(&codec_context);
        var format_context: ?*ffmpeg.AVFormatContext = self.format_context;
        ffmpeg.avformat_close_input(&format_context);

        self.allocator.free(self.output_pixels);
        self.* = undefined;
    }

    pub fn readFrame(self: *NativeDecoder) DecoderError!?FrameView {
        if (self.finished) return null;

        while (true) {
            const receive_result = ffmpeg.avcodec_receive_frame(
                self.codec_context,
                self.frame,
            );
            if (receive_result >= 0) return try self.convertCurrentFrame();
            if (receive_result == ffmpeg.AVERROR_EOF) {
                self.finished = true;
                return null;
            }
            if (receive_result != -@as(c_int, ffmpeg.EAGAIN)) {
                return error.DecodeFailed;
            }
            if (self.draining) return error.DecodeFailed;

            while (true) {
                const read_result = ffmpeg.av_read_frame(
                    self.format_context,
                    self.packet,
                );
                if (read_result < 0) {
                    if (read_result != ffmpeg.AVERROR_EOF) {
                        return error.DecodeFailed;
                    }
                    self.draining = true;
                    if (ffmpeg.avcodec_send_packet(self.codec_context, null) < 0) {
                        return error.DecodeFailed;
                    }
                    break;
                }

                if (self.packet.stream_index != self.video_stream_index) {
                    ffmpeg.av_packet_unref(self.packet);
                    continue;
                }

                const send_result = ffmpeg.avcodec_send_packet(
                    self.codec_context,
                    self.packet,
                );
                ffmpeg.av_packet_unref(self.packet);
                if (send_result < 0) return error.DecodeFailed;
                break;
            }
        }
    }

    fn convertCurrentFrame(self: *NativeDecoder) DecoderError!FrameView {
        if (self.frame.width != self.info.source.width or
            self.frame.height != self.info.source.height)
        {
            return error.UnsupportedResolutionChange;
        }
        if (self.frame.best_effort_timestamp == ffmpeg.AV_NOPTS_VALUE) {
            return error.MissingTimestamp;
        }

        const source_format: ffmpeg.AVPixelFormat = self.frame.format;
        const output_pixel_format: ffmpeg.AVPixelFormat =
            switch (self.output_format) {
            .gray8 => ffmpeg.AV_PIX_FMT_GRAY8,
            .bgra8_analysis, .bgra8 => ffmpeg.AV_PIX_FMT_BGRA,
        };
        const cached_context = ffmpeg.sws_getCachedContext(
            self.sws_context,
            self.frame.width,
            self.frame.height,
            source_format,
            @intCast(self.output_dimensions.width),
            @intCast(self.output_dimensions.height),
            output_pixel_format,
            ffmpeg.SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse {
            self.sws_context = null;
            return error.ConversionFailed;
        };
        self.sws_context = cached_context;
        const frame_color = ColorInfo{
            .range = @intCast(self.frame.color_range),
            .primaries = @intCast(self.frame.color_primaries),
            .transfer = @intCast(self.frame.color_trc),
            .matrix = @intCast(self.frame.colorspace),
            .chroma_location = @intCast(self.frame.chroma_location),
        };
        if (isHdrTransfer(frame_color.transfer) or
            isHdrTransfer(self.info.color.transfer))
        {
            std.log.err(
                "FFmpeg: vídeo HDR requer tone mapping antes do encode H.264 SDR",
                .{},
            );
            return error.UnsupportedHdrTransfer;
        }
        try configureColorConversion(
            cached_context,
            source_format,
            frame_color,
            self.info.color,
            self.info.source,
        );

        var destination_data = [_][*c]u8{
            self.output_pixels.ptr, null, null, null, null, null, null, null,
        };
        var destination_stride = [_]c_int{
            @intCast(self.output_stride), 0, 0, 0, 0, 0, 0, 0,
        };
        var source_data: [8][*c]const u8 = .{
            null, null, null, null, null, null, null, null,
        };
        var source_stride: [8]c_int = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        for (0..source_data.len) |plane| {
            source_data[plane] = self.frame.data[plane];
            source_stride[plane] = self.frame.linesize[plane];
        }
        const converted_rows = ffmpeg.sws_scale(
            cached_context,
            &source_data,
            &source_stride,
            0,
            self.frame.height,
            &destination_data,
            &destination_stride,
        );
        if (converted_rows != self.output_dimensions.height) {
            return error.ConversionFailed;
        }

        const duration: ?i64 = if (self.frame.duration > 0)
            self.frame.duration
        else
            null;
        const timing = types.FrameTiming{
            .index = self.next_index,
            .pts = self.frame.best_effort_timestamp,
            .duration = duration,
            .time_base = self.info.time_base,
        };
        timing.validate() catch return error.InvalidTimeBase;
        self.next_index += 1;

        return .{
            .timing = timing,
            .pixels = self.output_pixels[0..self.output_frame_size],
            .width = self.output_dimensions.width,
            .height = self.output_dimensions.height,
            .stride = self.output_stride,
            .format = self.output_format,
        };
    }
};

fn streamDisplayRotation(stream: *ffmpeg.AVStream) f64 {
    if (@hasField(ffmpeg.AVCodecParameters, "nb_coded_side_data") and
        @hasDecl(ffmpeg, "av_packet_side_data_get"))
    {
        const parameters = stream.*.codecpar;
        const side_data = ffmpeg.av_packet_side_data_get(
            parameters.*.coded_side_data,
            parameters.*.nb_coded_side_data,
            ffmpeg.AV_PKT_DATA_DISPLAYMATRIX,
        );
        if (side_data) |value| {
            return displayRotationFromSideData(
                value.*.data,
                @intCast(value.*.size),
            );
        }
    } else if (@hasField(ffmpeg.AVStream, "nb_side_data")) {
        const count: usize = @intCast(stream.*.nb_side_data);
        for (0..count) |index| {
            const value = stream.*.side_data[index];
            if (value.type == ffmpeg.AV_PKT_DATA_DISPLAYMATRIX) {
                return displayRotationFromSideData(
                    value.data,
                    @intCast(value.size),
                );
            }
        }
    }
    return 0;
}

fn displayRotationFromSideData(data: [*c]const u8, size: usize) f64 {
    if (data == null or size < 9 * @sizeOf(i32)) return 0;
    const matrix: [*c]const i32 = @ptrCast(@alignCast(data));
    const rotation = ffmpeg.av_display_rotation_get(matrix);
    return if (std.math.isFinite(rotation)) rotation else 0;
}

fn configureColorConversion(
    context: *ffmpeg.SwsContext,
    source_format: ffmpeg.AVPixelFormat,
    frame_color: ColorInfo,
    stream_color: ColorInfo,
    dimensions: Dimensions,
) DecoderError!void {
    const color = ColorInfo{
        .range = preferSpecified(frame_color.range, stream_color.range, 0),
        .primaries = preferSpecified(
            frame_color.primaries,
            stream_color.primaries,
            2,
        ),
        .transfer = preferSpecified(
            frame_color.transfer,
            stream_color.transfer,
            2,
        ),
        .matrix = preferSpecified(frame_color.matrix, stream_color.matrix, 2),
        .chroma_location = preferSpecified(
            frame_color.chroma_location,
            stream_color.chroma_location,
            0,
        ),
    };
    const coefficients = ffmpeg.sws_getCoefficients(
        swsMatrix(color.matrix, dimensions),
    );
    const descriptor = ffmpeg.av_pix_fmt_desc_get(source_format);
    const source_is_rgb = descriptor != null and
        (descriptor.*.flags & ffmpeg.AV_PIX_FMT_FLAG_RGB) != 0;
    const source_is_full = color.range == ffmpeg.AVCOL_RANGE_JPEG or
        source_is_rgb;
    const result = ffmpeg.sws_setColorspaceDetails(
        context,
        coefficients,
        @intFromBool(source_is_full),
        coefficients,
        1,
        0,
        1 << 16,
        1 << 16,
    );
    if (result < 0) return error.ConversionFailed;
}

fn isHdrTransfer(transfer: i32) bool {
    return transfer == ffmpeg.AVCOL_TRC_SMPTE2084 or
        transfer == ffmpeg.AVCOL_TRC_ARIB_STD_B67;
}

fn preferSpecified(frame: i32, stream: i32, unspecified: i32) i32 {
    if (frame != unspecified) return frame;
    return stream;
}

pub fn swsMatrix(matrix: i32, dimensions: Dimensions) c_int {
    return switch (matrix) {
        ffmpeg.AVCOL_SPC_BT709 => ffmpeg.SWS_CS_ITU709,
        ffmpeg.AVCOL_SPC_FCC => ffmpeg.SWS_CS_FCC,
        ffmpeg.AVCOL_SPC_BT470BG,
        ffmpeg.AVCOL_SPC_SMPTE170M,
        => ffmpeg.SWS_CS_ITU601,
        ffmpeg.AVCOL_SPC_SMPTE240M => ffmpeg.SWS_CS_SMPTE240M,
        ffmpeg.AVCOL_SPC_BT2020_NCL,
        ffmpeg.AVCOL_SPC_BT2020_CL,
        => ffmpeg.SWS_CS_BT2020,
        else => if (dimensions.width >= 1280 or dimensions.height > 576)
            ffmpeg.SWS_CS_ITU709
        else
            ffmpeg.SWS_CS_DEFAULT,
    };
}

test "display dimensions follow quarter-turn metadata" {
    const landscape = Dimensions{ .width = 1920, .height = 1080 };
    try std.testing.expectEqual(
        Dimensions{ .width = 1080, .height = 1920 },
        orientedDimensions(landscape, 90),
    );
    try std.testing.expectEqual(
        Dimensions{ .width = 1080, .height = 1920 },
        orientedDimensions(landscape, -90),
    );
    try std.testing.expectEqual(
        landscape,
        orientedDimensions(landscape, 180),
    );
    try std.testing.expectEqual(
        landscape,
        orientedDimensions(landscape, std.math.nan(f64)),
    );
}

test "HDR transfer functions require explicit tone mapping" {
    if (!native_enabled) return error.SkipZigTest;
    try std.testing.expect(isHdrTransfer(ffmpeg.AVCOL_TRC_SMPTE2084));
    try std.testing.expect(isHdrTransfer(ffmpeg.AVCOL_TRC_ARIB_STD_B67));
    try std.testing.expect(!isHdrTransfer(ffmpeg.AVCOL_TRC_BT709));
}

test "swscale matrix follows metadata and resolution fallback" {
    if (!native_enabled) return error.SkipZigTest;
    try std.testing.expectEqual(
        @as(c_int, ffmpeg.SWS_CS_ITU709),
        swsMatrix(ffmpeg.AVCOL_SPC_BT709, .{ .width = 720, .height = 576 }),
    );
    try std.testing.expectEqual(
        @as(c_int, ffmpeg.SWS_CS_BT2020),
        swsMatrix(
            ffmpeg.AVCOL_SPC_BT2020_NCL,
            .{ .width = 3840, .height = 2160 },
        ),
    );
    try std.testing.expectEqual(
        @as(c_int, ffmpeg.SWS_CS_ITU709),
        swsMatrix(2, .{ .width = 1920, .height = 1080 }),
    );
    try std.testing.expectEqual(
        @as(c_int, ffmpeg.SWS_CS_DEFAULT),
        swsMatrix(2, .{ .width = 640, .height = 480 }),
    );
}
