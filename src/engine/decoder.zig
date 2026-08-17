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

pub fn estimateFrameCount(
    reported_frames: i64,
    frame_rate: ?types.Rational,
    duration_seconds: ?f64,
) ?u64 {
    if (reported_frames > 0) return @intCast(reported_frames);
    const rate = frame_rate orelse return null;
    const duration = duration_seconds orelse return null;
    if (rate.numerator <= 0 or rate.denominator <= 0 or
        !std.math.isFinite(duration) or duration <= 0)
    {
        return null;
    }
    const fps = @as(f64, @floatFromInt(rate.numerator)) /
        @as(f64, @floatFromInt(rate.denominator));
    const estimate = @round(duration * fps);
    if (!std.math.isFinite(estimate) or estimate < 1 or
        estimate > @as(f64, @floatFromInt(std.math.maxInt(u64))))
    {
        return null;
    }
    return @intFromFloat(estimate);
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
    source_color: ColorInfo,
    info: VideoInfo,
    output_dimensions: Dimensions,
    output_format: PixelFormat,
    output_pixels: []u8,
    output_frame_size: usize,
    output_stride: usize,
    hdr_pixels: ?[]u16 = null,
    hdr_linear_lut: ?[]f32 = null,
    sdr_transfer_lut: ?[]u8 = null,
    hdr_lut_transfer: i32 = color_transfer_unspecified,
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
        if (stream_index == averror_decoder_not_found) {
            return error.DecoderNotFound;
        }
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
        const estimated_frame_count = estimateFrameCount(
            stream.*.nb_frames,
            frame_rate,
            duration_seconds,
        );
        const source_color = ColorInfo{
            .range = @intCast(codec_context.color_range),
            .primaries = @intCast(codec_context.color_primaries),
            .transfer = @intCast(codec_context.color_trc),
            .matrix = @intCast(codec_context.colorspace),
            .chroma_location = @intCast(
                codec_context.chroma_sample_location,
            ),
        };

        return .{
            .allocator = allocator,
            .format_context = format_context,
            .codec_context = codec_context,
            .frame = frame,
            .packet = packet,
            .video_stream_index = stream_index,
            .source_color = source_color,
            .info = .{
                .source = source,
                .analysis = analysis,
                .display_rotation_degrees = display_rotation_degrees,
                .color = outputColorInfo(source_color),
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
        if (self.sdr_transfer_lut) |lut| self.allocator.free(lut);
        if (self.hdr_linear_lut) |lut| self.allocator.free(lut);
        if (self.hdr_pixels) |pixels| self.allocator.free(pixels);

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
        const frame_color = ColorInfo{
            .range = @intCast(self.frame.color_range),
            .primaries = @intCast(self.frame.color_primaries),
            .transfer = @intCast(self.frame.color_trc),
            .matrix = @intCast(self.frame.colorspace),
            .chroma_location = @intCast(self.frame.chroma_location),
        };
        const source_color = resolvedColorInfo(frame_color, self.source_color);
        const hdr_transfer = hdrTransfer(source_color.transfer);
        if (hdr_transfer != null) {
            try self.ensureHdrResources(source_color.transfer);
            // Some containers only expose HDR metadata on decoded frames.
            // Keep the public video information synchronized so the encoder
            // advertises the SDR result instead of stale source metadata.
            self.info.color = outputColorInfo(source_color);
        }
        const output_pixel_format: ffmpeg.AVPixelFormat = if (hdr_transfer != null)
            ffmpeg.AV_PIX_FMT_BGRA64LE
        else switch (self.output_format) {
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
        try configureColorConversion(
            cached_context,
            source_format,
            source_color,
            self.info.source,
        );

        const destination_pixels: [*c]u8 = if (hdr_transfer != null)
            @ptrCast(self.hdr_pixels.?.ptr)
        else
            self.output_pixels.ptr;
        const destination_row_bytes: usize = if (hdr_transfer != null)
            @as(usize, self.output_dimensions.width) * 4 * @sizeOf(u16)
        else
            self.output_stride;
        var destination_data = [_][*c]u8{
            destination_pixels, null, null, null, null, null, null, null,
        };
        var destination_stride = [_]c_int{
            @intCast(destination_row_bytes), 0, 0, 0, 0, 0, 0, 0,
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
        if (hdr_transfer != null) self.toneMapHdr(source_color);

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

    fn ensureHdrResources(
        self: *NativeDecoder,
        transfer: i32,
    ) std.mem.Allocator.Error!void {
        if (self.hdr_pixels == null) {
            const pixel_count = @as(usize, self.output_dimensions.width) *
                @as(usize, self.output_dimensions.height) * 4;
            const padding = @as(usize, ffmpeg.AV_INPUT_BUFFER_PADDING_SIZE) /
                @sizeOf(u16);
            self.hdr_pixels = try self.allocator.alloc(u16, pixel_count + padding);
        }
        if (self.hdr_linear_lut == null) {
            self.hdr_linear_lut = try self.allocator.alloc(f32, hdr_lut_size);
        }
        if (self.sdr_transfer_lut == null) {
            const lut = try self.allocator.alloc(u8, hdr_lut_size);
            for (lut, 0..) |*value, index| {
                const linear = @as(f64, @floatFromInt(index)) /
                    @as(f64, hdr_lut_size - 1);
                value.* = floatToByte(bt709Oetf(linear));
            }
            self.sdr_transfer_lut = lut;
        }
        if (self.hdr_lut_transfer != transfer) {
            const transfer_kind = hdrTransfer(transfer).?;
            for (self.hdr_linear_lut.?, 0..) |*value, index| {
                const encoded = @as(f64, @floatFromInt(index)) /
                    @as(f64, hdr_lut_size - 1);
                value.* = @floatCast(hdrToLinear(encoded, transfer_kind));
            }
            self.hdr_lut_transfer = transfer;
        }
    }

    fn toneMapHdr(self: *NativeDecoder, color: ColorInfo) void {
        const source = self.hdr_pixels.?;
        const linear_lut = self.hdr_linear_lut.?;
        const transfer_lut = self.sdr_transfer_lut.?;
        const width: usize = @intCast(self.output_dimensions.width);
        const height: usize = @intCast(self.output_dimensions.height);

        for (0..height) |row| {
            for (0..width) |column| {
                const pixel_index = (row * width + column) * 4;
                var blue = linear_lut[source[pixel_index]];
                var green = linear_lut[source[pixel_index + 1]];
                var red = linear_lut[source[pixel_index + 2]];
                if (color.primaries == color_primaries_bt2020) {
                    const converted_red = 1.660491 * red -
                        0.587641 * green - 0.072850 * blue;
                    const converted_green = -0.124550 * red +
                        1.132900 * green - 0.008349 * blue;
                    const converted_blue = -0.018151 * red -
                        0.100579 * green + 1.118730 * blue;
                    red = converted_red;
                    green = converted_green;
                    blue = converted_blue;
                }
                red = @max(red, 0);
                green = @max(green, 0);
                blue = @max(blue, 0);
                const luminance = 0.2126 * red + 0.7152 * green +
                    0.0722 * blue;
                const mapped_luminance = acesToneMap(luminance);
                const scale = if (luminance > 0.000001)
                    mapped_luminance / luminance
                else
                    0;
                red = std.math.clamp(red * scale, 0, 1);
                green = std.math.clamp(green * scale, 0, 1);
                blue = std.math.clamp(blue * scale, 0, 1);

                switch (self.output_format) {
                    .gray8 => {
                        self.output_pixels[row * self.output_stride + column] =
                            transfer_lut[linearLutIndex(mapped_luminance)];
                    },
                    .bgra8_analysis, .bgra8 => {
                        const output_index = row * self.output_stride + column * 4;
                        self.output_pixels[output_index] =
                            transfer_lut[linearLutIndex(blue)];
                        self.output_pixels[output_index + 1] =
                            transfer_lut[linearLutIndex(green)];
                        self.output_pixels[output_index + 2] =
                            transfer_lut[linearLutIndex(red)];
                        self.output_pixels[output_index + 3] = 255;
                    },
                }
            }
        }
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
    color: ColorInfo,
    dimensions: Dimensions,
) DecoderError!void {
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

const color_range_mpeg = 1;
// AVERROR_DECODER_NOT_FOUND is a negative FFmpeg tag whose unsigned C macro
// cannot be translated by Zig 0.13's C importer.
const averror_decoder_not_found: c_int = -1128613112;
const color_primaries_bt709 = 1;
const color_primaries_bt2020 = 9;
const color_transfer_bt709 = 1;
const color_transfer_unspecified = 2;
const color_transfer_pq = 16;
const color_transfer_hlg = 18;
const color_matrix_bt709 = 1;
const chroma_location_left = 1;
const hdr_lut_size = std.math.maxInt(u16) + 1;

const HdrTransfer = enum { pq, hlg };

fn hdrTransfer(transfer: i32) ?HdrTransfer {
    return switch (transfer) {
        color_transfer_pq => .pq,
        color_transfer_hlg => .hlg,
        else => null,
    };
}

fn outputColorInfo(source: ColorInfo) ColorInfo {
    if (hdrTransfer(source.transfer) == null) return source;
    return .{
        .range = color_range_mpeg,
        .primaries = color_primaries_bt709,
        .transfer = color_transfer_bt709,
        .matrix = color_matrix_bt709,
        .chroma_location = chroma_location_left,
    };
}

fn resolvedColorInfo(frame: ColorInfo, stream: ColorInfo) ColorInfo {
    return .{
        .range = preferSpecified(frame.range, stream.range, 0),
        .primaries = preferSpecified(frame.primaries, stream.primaries, 2),
        .transfer = preferSpecified(frame.transfer, stream.transfer, 2),
        .matrix = preferSpecified(frame.matrix, stream.matrix, 2),
        .chroma_location = preferSpecified(
            frame.chroma_location,
            stream.chroma_location,
            0,
        ),
    };
}

fn hdrToLinear(encoded: f64, transfer: HdrTransfer) f64 {
    return switch (transfer) {
        .pq => blk: {
            const m1 = 2610.0 / 16384.0;
            const m2 = 2523.0 / 32.0;
            const c1 = 3424.0 / 4096.0;
            const c2 = 2413.0 / 128.0;
            const c3 = 2392.0 / 128.0;
            const power = std.math.pow(f64, encoded, 1.0 / m2);
            const numerator = @max(power - c1, 0);
            const denominator = @max(c2 - c3 * power, 0.000001);
            // PQ is absolute up to 10,000 nits. Express it relative to the
            // 100-nit SDR display targeted by the output transfer function.
            break :blk std.math.pow(f64, numerator / denominator, 1.0 / m1) * 100.0;
        },
        .hlg => blk: {
            const a = 0.17883277;
            const b = 0.28466892;
            const c = 0.55991073;
            const scene_linear = if (encoded <= 0.5)
                encoded * encoded / 3.0
            else
                (@exp((encoded - c) / a) + b) / 12.0;
            // Maps HLG's nominal 75% reference white close to SDR diffuse
            // white before highlight compression.
            break :blk scene_linear * 3.75;
        },
    };
}

fn acesToneMap(linear: f32) f32 {
    if (linear <= 0) return 0;
    const numerator = linear * (2.51 * linear + 0.03);
    const denominator = linear * (2.43 * linear + 0.59) + 0.14;
    return std.math.clamp(numerator / denominator, 0, 1);
}

fn bt709Oetf(linear: f64) f64 {
    const value = std.math.clamp(linear, 0, 1);
    return if (value < 0.018)
        4.5 * value
    else
        1.099 * std.math.pow(f64, value, 0.45) - 0.099;
}

fn floatToByte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}

fn linearLutIndex(value: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) *
        @as(f32, @floatFromInt(hdr_lut_size - 1))));
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

test "frame count falls back to duration and frame rate" {
    const rate = types.Rational{ .numerator = 30, .denominator = 1 };
    try std.testing.expectEqual(
        @as(?u64, 120),
        estimateFrameCount(120, null, null),
    );
    try std.testing.expectEqual(
        @as(?u64, 60),
        estimateFrameCount(0, rate, 2.003),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        estimateFrameCount(0, rate, std.math.nan(f64)),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        estimateFrameCount(0, null, 2),
    );
}

test "HDR transfer functions select tone mapping and SDR metadata" {
    try std.testing.expectEqual(HdrTransfer.pq, hdrTransfer(color_transfer_pq).?);
    try std.testing.expectEqual(HdrTransfer.hlg, hdrTransfer(color_transfer_hlg).?);
    try std.testing.expectEqual(@as(?HdrTransfer, null), hdrTransfer(color_transfer_bt709));

    const output = outputColorInfo(.{
        .range = color_range_mpeg,
        .primaries = color_primaries_bt2020,
        .transfer = color_transfer_pq,
        .matrix = 9,
    });
    try std.testing.expectEqual(color_primaries_bt709, output.primaries);
    try std.testing.expectEqual(color_transfer_bt709, output.transfer);
    try std.testing.expectEqual(color_matrix_bt709, output.matrix);
}

test "HDR tone mapping curves are finite and monotonic" {
    inline for (.{ HdrTransfer.pq, HdrTransfer.hlg }) |transfer| {
        var previous: f64 = -1;
        for (0..257) |index| {
            const encoded = @as(f64, @floatFromInt(index)) / 256.0;
            const linear = hdrToLinear(encoded, transfer);
            try std.testing.expect(std.math.isFinite(linear));
            try std.testing.expect(linear >= previous);
            previous = linear;
        }
    }
    try std.testing.expectEqual(@as(u8, 0), floatToByte(bt709Oetf(0)));
    try std.testing.expectEqual(@as(u8, 255), floatToByte(bt709Oetf(1)));
    try std.testing.expect(acesToneMap(4) > acesToneMap(1));
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
