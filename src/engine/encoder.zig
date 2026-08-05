const std = @import("std");
const build_options = @import("build_options");
const decoder = @import("decoder.zig");
const renderer = @import("renderer.zig");
const types = @import("types.zig");

const ffmpeg = if (build_options.native_ffmpeg) @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswscale/swscale.h");
}) else struct {};

pub const native_enabled = build_options.native_ffmpeg;

pub const Options = struct {
    crf: u8 = 18,
    preset: []const u8 = "medium",
    gop_size: u16 = 120,
    max_b_frames: u8 = 2,
};

pub const EncoderError = error{
    BackendNotEnabled,
    EmptyPath,
    InvalidDimensions,
    InvalidOptions,
    OutputContextFailed,
    EncoderNotFound,
    StreamAllocationFailed,
    CodecAllocationFailed,
    CodecOpenFailed,
    ParameterCopyFailed,
    OutputOpenFailed,
    HeaderWriteFailed,
    FrameAllocationFailed,
    PacketAllocationFailed,
    ScaleContextFailed,
    PixelFormatMismatch,
    InvalidStride,
    PixelBufferTooSmall,
    NonMonotonicPts,
    FrameConversionFailed,
    EncodeFailed,
    PacketWriteFailed,
    TrailerWriteFailed,
    SizeOverflow,
} || types.ValidationError || std.mem.Allocator.Error;

pub const Encoder = if (native_enabled) NativeEncoder else DisabledEncoder;

const DisabledEncoder = struct {
    pub fn create(
        allocator: std.mem.Allocator,
        output_path: []const u8,
        source_dimensions: decoder.Dimensions,
        time_base: types.Rational,
        frame_rate: ?types.Rational,
        options: Options,
    ) EncoderError!DisabledEncoder {
        _ = allocator;
        _ = output_path;
        _ = source_dimensions;
        _ = time_base;
        _ = frame_rate;
        _ = options;
        return error.BackendNotEnabled;
    }

    pub fn deinit(self: *DisabledEncoder) void {
        self.* = undefined;
    }

    pub fn writeFrame(
        self: *DisabledEncoder,
        frame: renderer.Frame,
    ) EncoderError!void {
        _ = self;
        _ = frame;
        return error.BackendNotEnabled;
    }

    pub fn finish(self: *DisabledEncoder) EncoderError!void {
        _ = self;
        return error.BackendNotEnabled;
    }
};

const NativeEncoder = struct {
    output_context: *ffmpeg.AVFormatContext,
    codec_context: *ffmpeg.AVCodecContext,
    stream: *ffmpeg.AVStream,
    frame: *ffmpeg.AVFrame,
    packet: *ffmpeg.AVPacket,
    sws_context: *ffmpeg.SwsContext,
    source_dimensions: decoder.Dimensions,
    output_dimensions: decoder.Dimensions,
    io_open: bool,
    finished: bool = false,
    last_pts: ?i64 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        output_path: []const u8,
        source_dimensions: decoder.Dimensions,
        time_base: types.Rational,
        frame_rate: ?types.Rational,
        options: Options,
    ) EncoderError!NativeEncoder {
        if (output_path.len == 0) return error.EmptyPath;
        if (source_dimensions.width < 2 or source_dimensions.height < 2) {
            return error.InvalidDimensions;
        }
        try time_base.validate();
        if (options.crf > 51 or options.preset.len == 0 or
            options.gop_size == 0 or options.max_b_frames > 16)
        {
            return error.InvalidOptions;
        }

        const output_dimensions = decoder.Dimensions{
            .width = source_dimensions.width - source_dimensions.width % 2,
            .height = source_dimensions.height - source_dimensions.height % 2,
        };
        const path_z = try allocator.dupeZ(u8, output_path);
        defer allocator.free(path_z);

        var output_optional: ?*ffmpeg.AVFormatContext = null;
        const output_result = ffmpeg.avformat_alloc_output_context2(
            &output_optional,
            null,
            null,
            path_z.ptr,
        );
        if (output_result < 0) {
            logFfmpegError("criando o contêiner de saída", output_result);
            return error.OutputContextFailed;
        }
        const output_context = output_optional orelse
            return error.OutputContextFailed;
        errdefer ffmpeg.avformat_free_context(output_context);

        const codec = ffmpeg.avcodec_find_encoder_by_name("libx264") orelse
            ffmpeg.avcodec_find_encoder_by_name("libopenh264") orelse
            ffmpeg.avcodec_find_encoder(ffmpeg.AV_CODEC_ID_H264) orelse
            return error.EncoderNotFound;
        const codec_name = std.mem.span(codec.*.name);
        const uses_openh264 = std.mem.eql(
            u8,
            codec_name,
            "libopenh264",
        );
        const stream: *ffmpeg.AVStream = ffmpeg.avformat_new_stream(
            output_context,
            null,
        ) orelse return error.StreamAllocationFailed;

        var codec_optional: ?*ffmpeg.AVCodecContext =
            ffmpeg.avcodec_alloc_context3(codec);
        const codec_context = codec_optional orelse
            return error.CodecAllocationFailed;
        errdefer ffmpeg.avcodec_free_context(&codec_optional);

        codec_context.width = @intCast(output_dimensions.width);
        codec_context.height = @intCast(output_dimensions.height);
        codec_context.pix_fmt = ffmpeg.AV_PIX_FMT_YUV420P;
        codec_context.time_base = .{
            .num = time_base.numerator,
            .den = time_base.denominator,
        };

        if (frame_rate) |fr| {
            codec_context.framerate = .{
                .num = fr.numerator,
                .den = fr.denominator,
            };
        } else {
            codec_context.framerate = .{ .num = 30, .den = 1 };
        }

        codec_context.gop_size = @intCast(options.gop_size);
        // OpenH264 does not encode B-frames. Advertising them in the context
        // creates misleading timing expectations for the surrounding muxer.
        codec_context.max_b_frames = if (uses_openh264)
            0
        else
            @intCast(options.max_b_frames);
        if ((output_context.oformat.*.flags &
            ffmpeg.AVFMT_GLOBALHEADER) != 0)
        {
            codec_context.flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        var codec_options: ?*ffmpeg.AVDictionary = null;
        defer ffmpeg.av_dict_free(&codec_options);
        if (uses_openh264) {
            // CRF and preset are libx264-only. OpenH264's supported equivalent
            // is fixed-QP mode: disable rate control and constrain QP to the
            // requested CRF-like quality value.
            const quantizer: c_int = @intCast(@max(1, options.crf));
            codec_context.qmin = quantizer;
            codec_context.qmax = quantizer;
            if (ffmpeg.av_dict_set(
                &codec_options,
                "rc_mode",
                "off",
                0,
            ) < 0 or ffmpeg.av_dict_set(
                &codec_options,
                "profile",
                "high",
                0,
            ) < 0) {
                return error.InvalidOptions;
            }
        } else {
            const preset_z = try allocator.dupeZ(u8, options.preset);
            defer allocator.free(preset_z);
            var crf_buffer: [4]u8 = undefined;
            const crf_z = std.fmt.bufPrintZ(
                &crf_buffer,
                "{d}",
                .{options.crf},
            ) catch return error.InvalidOptions;
            if (ffmpeg.av_dict_set(
                &codec_options,
                "preset",
                preset_z.ptr,
                0,
            ) < 0 or ffmpeg.av_dict_set(
                &codec_options,
                "crf",
                crf_z.ptr,
                0,
            ) < 0) {
                return error.InvalidOptions;
            }
        }
        const open_result = ffmpeg.avcodec_open2(
            codec_context,
            codec,
            &codec_options,
        );
        if (open_result < 0) {
            logFfmpegError("abrindo o encoder H.264", open_result);
            return error.CodecOpenFailed;
        }
        // avcodec_open2 removes every recognized dictionary entry. Leftovers
        // mean the selected backend silently ignored a quality setting.
        if (ffmpeg.av_dict_count(codec_options) != 0) {
            return error.InvalidOptions;
        }

        stream.time_base = codec_context.time_base;
        const parameters_result = ffmpeg.avcodec_parameters_from_context(
            stream.codecpar,
            codec_context,
        );
        if (parameters_result < 0) {
            logFfmpegError(
                "copiando os parâmetros do encoder",
                parameters_result,
            );
            return error.ParameterCopyFailed;
        }

        var io_open = false;
        errdefer if (io_open) {
            _ = ffmpeg.avio_closep(&output_context.pb);
        };
        if ((output_context.oformat.*.flags & ffmpeg.AVFMT_NOFILE) == 0) {
            const io_result = ffmpeg.avio_open(
                &output_context.pb,
                path_z.ptr,
                ffmpeg.AVIO_FLAG_WRITE,
            );
            if (io_result < 0) {
                logFfmpegError("abrindo o arquivo de saída", io_result);
                return error.OutputOpenFailed;
            }
            io_open = true;
        }

        var muxer_options: ?*ffmpeg.AVDictionary = null;
        defer ffmpeg.av_dict_free(&muxer_options);
        _ = ffmpeg.av_dict_set(
            &muxer_options,
            "movflags",
            "+faststart",
            0,
        );
        const header_result = ffmpeg.avformat_write_header(
            output_context,
            &muxer_options,
        );
        if (header_result < 0) {
            logFfmpegError("gravando o cabeçalho do vídeo", header_result);
            return error.HeaderWriteFailed;
        }

        const frame: *ffmpeg.AVFrame = ffmpeg.av_frame_alloc() orelse
            return error.FrameAllocationFailed;
        errdefer {
            var value: ?*ffmpeg.AVFrame = frame;
            ffmpeg.av_frame_free(&value);
        }
        frame.format = ffmpeg.AV_PIX_FMT_YUV420P;
        frame.width = @intCast(output_dimensions.width);
        frame.height = @intCast(output_dimensions.height);
        const frame_buffer_result = ffmpeg.av_frame_get_buffer(frame, 32);
        if (frame_buffer_result < 0) {
            logFfmpegError("alocando o frame do encoder", frame_buffer_result);
            return error.FrameAllocationFailed;
        }

        const packet: *ffmpeg.AVPacket = ffmpeg.av_packet_alloc() orelse
            return error.PacketAllocationFailed;
        errdefer {
            var value: ?*ffmpeg.AVPacket = packet;
            ffmpeg.av_packet_free(&value);
        }

        const sws_context = ffmpeg.sws_getContext(
            @intCast(source_dimensions.width),
            @intCast(source_dimensions.height),
            ffmpeg.AV_PIX_FMT_BGRA,
            @intCast(output_dimensions.width),
            @intCast(output_dimensions.height),
            ffmpeg.AV_PIX_FMT_YUV420P,
            ffmpeg.SWS_BICUBIC,
            null,
            null,
            null,
        ) orelse return error.ScaleContextFailed;
        errdefer ffmpeg.sws_freeContext(sws_context);

        return .{
            .output_context = output_context,
            .codec_context = codec_context,
            .stream = stream,
            .frame = frame,
            .packet = packet,
            .sws_context = sws_context,
            .source_dimensions = source_dimensions,
            .output_dimensions = output_dimensions,
            .io_open = io_open,
        };
    }

    pub fn deinit(self: *NativeEncoder) void {
        ffmpeg.sws_freeContext(self.sws_context);
        var packet: ?*ffmpeg.AVPacket = self.packet;
        ffmpeg.av_packet_free(&packet);
        var frame: ?*ffmpeg.AVFrame = self.frame;
        ffmpeg.av_frame_free(&frame);
        var codec: ?*ffmpeg.AVCodecContext = self.codec_context;
        ffmpeg.avcodec_free_context(&codec);
        if (self.io_open) {
            _ = ffmpeg.avio_closep(&self.output_context.pb);
        }
        ffmpeg.avformat_free_context(self.output_context);
        self.* = undefined;
    }

    pub fn writeFrame(
        self: *NativeEncoder,
        input: renderer.Frame,
    ) EncoderError!void {
        if (self.finished) return error.EncodeFailed;
        if (input.format != .bgra8) return error.PixelFormatMismatch;
        if (input.width != self.source_dimensions.width or
            input.height != self.source_dimensions.height)
        {
            return error.InvalidDimensions;
        }
        try input.timing.validate();
        const row_bytes = std.math.mul(
            usize,
            @as(usize, input.width),
            decoder.PixelFormat.bgra8.bytesPerPixel(),
        ) catch return error.SizeOverflow;
        if (input.stride < row_bytes) return error.InvalidStride;
        const required = std.math.mul(
            usize,
            input.stride,
            @as(usize, input.height),
        ) catch return error.SizeOverflow;
        if (input.pixels.len < required) return error.PixelBufferTooSmall;

        const pts = ffmpeg.av_rescale_q(
            input.timing.pts,
            .{
                .num = input.timing.time_base.numerator,
                .den = input.timing.time_base.denominator,
            },
            self.codec_context.time_base,
        );
        if (self.last_pts) |last| {
            if (pts <= last) return error.NonMonotonicPts;
        }
        self.last_pts = pts;

        const writable_result = ffmpeg.av_frame_make_writable(self.frame);
        if (writable_result < 0) {
            logFfmpegError("preparando o frame do encoder", writable_result);
            return error.FrameAllocationFailed;
        }

        // Proteção contra leitura fora do índice 3 no array C
        var source_data = [_][*c]const u8{
            input.pixels.ptr, null, null, null, null, null, null, null,
        };
        var source_stride = [_]c_int{
            @intCast(input.stride), 0, 0, 0, 0, 0, 0, 0,
        };

        const converted = ffmpeg.sws_scale(
            self.sws_context,
            &source_data,
            &source_stride,
            0,
            @intCast(input.height),
            &self.frame.data,
            &self.frame.linesize,
        );
        if (converted != self.output_dimensions.height) {
            return error.FrameConversionFailed;
        }

        self.frame.pts = pts;
        self.frame.duration = if (input.timing.duration) |duration|
            ffmpeg.av_rescale_q(
                duration,
                .{
                    .num = input.timing.time_base.numerator,
                    .den = input.timing.time_base.denominator,
                },
                self.codec_context.time_base,
            )
        else
            0;
        const send_result = ffmpeg.avcodec_send_frame(
            self.codec_context,
            self.frame,
        );
        if (send_result < 0) {
            logFfmpegError("enviando um frame ao encoder", send_result);
            return error.EncodeFailed;
        }
        try self.writeAvailablePackets();
    }

    pub fn finish(self: *NativeEncoder) EncoderError!void {
        if (self.finished) return;
        const flush_result = ffmpeg.avcodec_send_frame(
            self.codec_context,
            null,
        );
        if (flush_result < 0) {
            logFfmpegError("finalizando o encoder", flush_result);
            return error.EncodeFailed;
        }
        try self.writeAvailablePackets();
        const trailer_result = ffmpeg.av_write_trailer(self.output_context);
        if (trailer_result < 0) {
            logFfmpegError("gravando o trailer do vídeo", trailer_result);
            return error.TrailerWriteFailed;
        }
        self.finished = true;
    }

    fn writeAvailablePackets(self: *NativeEncoder) EncoderError!void {
        while (true) {
            const result = ffmpeg.avcodec_receive_packet(
                self.codec_context,
                self.packet,
            );
            if (result == -@as(c_int, ffmpeg.EAGAIN)) return;
            if (result == ffmpeg.AVERROR_EOF) return;
            if (result < 0) {
                logFfmpegError("recebendo um pacote do encoder", result);
                return error.EncodeFailed;
            }

            ffmpeg.av_packet_rescale_ts(
                self.packet,
                self.codec_context.time_base,
                self.stream.time_base,
            );
            self.packet.stream_index = self.stream.index;
            const write_result = ffmpeg.av_interleaved_write_frame(
                self.output_context,
                self.packet,
            );

            // Unref explícito obrigatório após o envio para não vazar memória no write loop
            ffmpeg.av_packet_unref(self.packet);

            if (write_result < 0) {
                logFfmpegError("gravando um pacote de vídeo", write_result);
                return error.PacketWriteFailed;
            }
        }
    }
};

fn logFfmpegError(operation: []const u8, code: c_int) void {
    var buffer: [256]u8 = undefined;
    if (ffmpeg.av_strerror(code, &buffer, buffer.len) == 0) {
        const message = std.mem.sliceTo(buffer[0..], 0);
        std.log.err("FFmpeg: {s}: {s} ({d})", .{
            operation,
            message,
            code,
        });
    } else {
        std.log.err("FFmpeg: {s}: código {d}", .{ operation, code });
    }
}
