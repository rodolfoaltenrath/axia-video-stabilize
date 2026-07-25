const std = @import("std");
const build_options = @import("build_options");

const ffmpeg = if (build_options.native_ffmpeg) @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
}) else struct {};

pub const native_enabled = build_options.native_ffmpeg;

pub const Options = struct {
    copy_metadata: bool = true,
    require_audio: bool = false,
    faststart: bool = true,
};

pub const Result = struct {
    audio_streams: u32,
};

pub const MuxError = error{
    BackendNotEnabled,
    EmptyPath,
    OpenVideoFailed,
    OpenSourceFailed,
    StreamInfoFailed,
    VideoStreamNotFound,
    OutputContextFailed,
    StreamAllocationFailed,
    ParameterCopyFailed,
    MetadataCopyFailed,
    AudioRequired,
    OutputOpenFailed,
    HeaderWriteFailed,
    PacketAllocationFailed,
    PacketReadFailed,
    PacketWriteFailed,
    TrailerWriteFailed,
    StreamIndexInvalid,
} || std.mem.Allocator.Error;

pub const Muxer = if (native_enabled) NativeMuxer else DisabledMuxer;

const DisabledMuxer = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        video_path: []const u8,
        source_path: []const u8,
        output_path: []const u8,
        options: Options,
    ) MuxError!Result {
        _ = allocator;
        _ = video_path;
        _ = source_path;
        _ = output_path;
        _ = options;
        return error.BackendNotEnabled;
    }
};

const NativeMuxer = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        video_path: []const u8,
        source_path: []const u8,
        output_path: []const u8,
        options: Options,
    ) MuxError!Result {
        if (video_path.len == 0 or source_path.len == 0 or
            output_path.len == 0)
        {
            return error.EmptyPath;
        }

        var video_input = try openInput(
            allocator,
            video_path,
            error.OpenVideoFailed,
        );
        defer closeInput(&video_input);
        var source_input = try openInput(
            allocator,
            source_path,
            error.OpenSourceFailed,
        );
        defer closeInput(&source_input);

        const video_stream_index = ffmpeg.av_find_best_stream(
            video_input,
            ffmpeg.AVMEDIA_TYPE_VIDEO,
            -1,
            -1,
            null,
            0,
        );
        if (video_stream_index < 0) return error.VideoStreamNotFound;

        const output_path_z = try allocator.dupeZ(u8, output_path);
        defer allocator.free(output_path_z);
        var output_optional: ?*ffmpeg.AVFormatContext = null;
        if (ffmpeg.avformat_alloc_output_context2(
            &output_optional,
            null,
            null,
            output_path_z.ptr,
        ) < 0) {
            return error.OutputContextFailed;
        }
        const output = output_optional orelse
            return error.OutputContextFailed;
        errdefer ffmpeg.avformat_free_context(output);

        const input_video_stream =
            video_input.streams[@intCast(video_stream_index)];
        const output_video_stream = ffmpeg.avformat_new_stream(
            output,
            null,
        ) orelse return error.StreamAllocationFailed;
        if (ffmpeg.avcodec_parameters_copy(
            output_video_stream.*.codecpar,
            input_video_stream.*.codecpar,
        ) < 0) {
            return error.ParameterCopyFailed;
        }
        output_video_stream.*.codecpar.*.codec_tag = 0;
        output_video_stream.*.time_base = input_video_stream.*.time_base;

        const source_stream_count: usize = @intCast(source_input.nb_streams);
        const stream_mapping = try allocator.alloc(
            c_int,
            source_stream_count,
        );
        defer allocator.free(stream_mapping);
        @memset(stream_mapping, -1);

        var audio_stream_count: u32 = 0;
        for (0..source_stream_count) |input_index| {
            const input_stream = source_input.streams[input_index];
            if (input_stream.*.codecpar.*.codec_type !=
                ffmpeg.AVMEDIA_TYPE_AUDIO)
            {
                continue;
            }
            const output_stream = ffmpeg.avformat_new_stream(
                output,
                null,
            ) orelse return error.StreamAllocationFailed;
            if (ffmpeg.avcodec_parameters_copy(
                output_stream.*.codecpar,
                input_stream.*.codecpar,
            ) < 0) {
                return error.ParameterCopyFailed;
            }
            output_stream.*.codecpar.*.codec_tag = 0;
            output_stream.*.time_base = input_stream.*.time_base;
            if (options.copy_metadata and ffmpeg.av_dict_copy(
                &output_stream.*.metadata,
                input_stream.*.metadata,
                0,
            ) < 0) {
                return error.MetadataCopyFailed;
            }
            stream_mapping[input_index] = output_stream.*.index;
            audio_stream_count += 1;
        }
        if (options.require_audio and audio_stream_count == 0) {
            return error.AudioRequired;
        }

        if (options.copy_metadata) {
            if (ffmpeg.av_dict_copy(
                &output.metadata,
                source_input.metadata,
                0,
            ) < 0) {
                return error.MetadataCopyFailed;
            }
            const source_video_index = ffmpeg.av_find_best_stream(
                source_input,
                ffmpeg.AVMEDIA_TYPE_VIDEO,
                -1,
                -1,
                null,
                0,
            );
            if (source_video_index >= 0) {
                const source_video =
                    source_input.streams[@intCast(source_video_index)];
                
                // Copia o dicionário de tags tradicionais
                if (ffmpeg.av_dict_copy(
                    &output_video_stream.*.metadata,
                    source_video.*.metadata,
                    0,
                ) < 0) {
                    return error.MetadataCopyFailed;
                }

                // RECUPERAÇÃO DA DISPLAY MATRIX (ROTAÇÃO 9:16)
                // Checagem Comptime Segura para FFmpeg legado (até v6.x)
                if (@hasField(ffmpeg.AVStream, "nb_side_data") and @hasDecl(ffmpeg, "av_stream_new_side_data")) {
                    const nb_side: usize = @intCast(source_video.*.nb_side_data);
                    for (0..nb_side) |i| {
                        const sd = source_video.*.side_data[i];
                        if (sd.type == ffmpeg.AV_PKT_DATA_DISPLAYMATRIX) {
                            const dst = ffmpeg.av_stream_new_side_data(
                                output_video_stream,
                                sd.type,
                                @intCast(sd.size),
                            );
                            if (dst != null) {
                                const size: usize = @intCast(sd.size);
                                @memcpy(dst[0..size], sd.data[0..size]);
                            }
                        }
                    }
                }

                // Checagem Comptime Segura para FFmpeg moderno (v6.x, v7.x+)
                if (@hasField(ffmpeg.AVCodecParameters, "nb_coded_side_data") and @hasDecl(ffmpeg, "av_packet_side_data_add")) {
                    const nb_side: usize = @intCast(source_video.*.codecpar.*.nb_coded_side_data);
                    for (0..nb_side) |i| {
                        const sd = source_video.*.codecpar.*.coded_side_data[i];
                        if (sd.type == ffmpeg.AV_PKT_DATA_DISPLAYMATRIX) {
                            _ = ffmpeg.av_packet_side_data_add(
                                &output_video_stream.*.codecpar.*.coded_side_data,
                                &output_video_stream.*.codecpar.*.nb_coded_side_data,
                                sd.type,
                                sd.data,
                                sd.size,
                                0,
                            );
                        }
                    }
                }
            }
        }

        var io_open = false;
        errdefer if (io_open) {
            _ = ffmpeg.avio_closep(&output.pb);
        };
        if ((output.oformat.*.flags & ffmpeg.AVFMT_NOFILE) == 0) {
            if (ffmpeg.avio_open(
                &output.pb,
                output_path_z.ptr,
                ffmpeg.AVIO_FLAG_WRITE,
            ) < 0) {
                return error.OutputOpenFailed;
            }
            io_open = true;
        }

        var muxer_options: ?*ffmpeg.AVDictionary = null;
        defer ffmpeg.av_dict_free(&muxer_options);
        if (options.faststart) {
            _ = ffmpeg.av_dict_set(
                &muxer_options,
                "movflags",
                "+faststart",
                0,
            );
        }
        if (ffmpeg.avformat_write_header(output, &muxer_options) < 0) {
            return error.HeaderWriteFailed;
        }

        const video_packet = ffmpeg.av_packet_alloc() orelse
            return error.PacketAllocationFailed;
        defer {
            var value: ?*ffmpeg.AVPacket = video_packet;
            ffmpeg.av_packet_free(&value);
        }
        const audio_packet = ffmpeg.av_packet_alloc() orelse
            return error.PacketAllocationFailed;
        defer {
            var value: ?*ffmpeg.AVPacket = audio_packet;
            ffmpeg.av_packet_free(&value);
        }

        var video_ready = false;
        var audio_ready = false;
        var video_eof = false;
        var audio_eof = false;
        while (!video_eof or !audio_eof or video_ready or audio_ready) {
            if (!video_ready and !video_eof) {
                video_ready = try readNextVideoPacket(
                    video_input,
                    video_stream_index,
                    video_packet,
                    &video_eof,
                );
            }
            if (!audio_ready and !audio_eof) {
                audio_ready = try readNextAudioPacket(
                    source_input,
                    stream_mapping,
                    audio_packet,
                    &audio_eof,
                );
            }
            if (!video_ready and !audio_ready) continue;

            const write_video = if (!audio_ready)
                true
            else if (!video_ready)
                false
            else
                packetComesFirst(
                    video_packet,
                    input_video_stream.*.time_base,
                    audio_packet,
                    source_input.streams[
                        @intCast(audio_packet.*.stream_index)
                    ].*.time_base,
                );
            if (write_video) {
                try writePacket(
                    output,
                    video_packet,
                    input_video_stream.*.time_base,
                    output_video_stream.*.time_base,
                    output_video_stream.*.index,
                );
                video_ready = false;
            } else {
                const source_index: usize =
                    @intCast(audio_packet.*.stream_index);
                if (source_index >= stream_mapping.len or
                    stream_mapping[source_index] < 0)
                {
                    return error.StreamIndexInvalid;
                }
                const output_index = stream_mapping[source_index];
                const output_stream =
                    output.streams[@intCast(output_index)];
                try writePacket(
                    output,
                    audio_packet,
                    source_input.streams[source_index].*.time_base,
                    output_stream.*.time_base,
                    output_index,
                );
                audio_ready = false;
            }
        }

        if (ffmpeg.av_write_trailer(output) < 0) {
            return error.TrailerWriteFailed;
        }
        if (io_open) {
            _ = ffmpeg.avio_closep(&output.pb);
            io_open = false;
        }
        ffmpeg.avformat_free_context(output);
        return .{ .audio_streams = audio_stream_count };
    }
};

fn openInput(
    allocator: std.mem.Allocator,
    path: []const u8,
    open_error: MuxError,
) MuxError!*ffmpeg.AVFormatContext {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var context_optional: ?*ffmpeg.AVFormatContext = null;
    if (ffmpeg.avformat_open_input(
        &context_optional,
        path_z.ptr,
        null,
        null,
    ) < 0) {
        return open_error;
    }
    const context = context_optional orelse return open_error;
    errdefer {
        var value: ?*ffmpeg.AVFormatContext = context;
        ffmpeg.avformat_close_input(&value);
    }
    if (ffmpeg.avformat_find_stream_info(context, null) < 0) {
        return error.StreamInfoFailed;
    }
    return context;
}

fn closeInput(context: **ffmpeg.AVFormatContext) void {
    var optional: ?*ffmpeg.AVFormatContext = context.*;
    ffmpeg.avformat_close_input(&optional);
    context.* = undefined;
}

fn readNextVideoPacket(
    context: *ffmpeg.AVFormatContext,
    video_stream_index: c_int,
    packet: *ffmpeg.AVPacket,
    eof: *bool,
) MuxError!bool {
    while (true) {
        const result = ffmpeg.av_read_frame(context, packet);
        if (result == ffmpeg.AVERROR_EOF) {
            eof.* = true;
            return false;
        }
        if (result < 0) return error.PacketReadFailed;
        if (packet.stream_index == video_stream_index) return true;
        ffmpeg.av_packet_unref(packet);
    }
}

fn readNextAudioPacket(
    context: *ffmpeg.AVFormatContext,
    stream_mapping: []const c_int,
    packet: *ffmpeg.AVPacket,
    eof: *bool,
) MuxError!bool {
    while (true) {
        const result = ffmpeg.av_read_frame(context, packet);
        if (result == ffmpeg.AVERROR_EOF) {
            eof.* = true;
            return false;
        }
        if (result < 0) return error.PacketReadFailed;
        if (packet.stream_index >= 0) {
            const index: usize = @intCast(packet.stream_index);
            if (index < stream_mapping.len and stream_mapping[index] >= 0) {
                return true;
            }
        }
        ffmpeg.av_packet_unref(packet);
    }
}

fn packetComesFirst(
    first: *const ffmpeg.AVPacket,
    first_time_base: ffmpeg.AVRational,
    second: *const ffmpeg.AVPacket,
    second_time_base: ffmpeg.AVRational,
) bool {
    const first_timestamp = packetTimestamp(first);
    const second_timestamp = packetTimestamp(second);
    if (first_timestamp == ffmpeg.AV_NOPTS_VALUE) return false;
    if (second_timestamp == ffmpeg.AV_NOPTS_VALUE) return true;
    return ffmpeg.av_compare_ts(
        first_timestamp,
        first_time_base,
        second_timestamp,
        second_time_base,
    ) <= 0;
}

fn packetTimestamp(packet: *const ffmpeg.AVPacket) i64 {
    if (packet.dts != ffmpeg.AV_NOPTS_VALUE) return packet.dts;
    return packet.pts;
}

fn writePacket(
    output: *ffmpeg.AVFormatContext,
    packet: *ffmpeg.AVPacket,
    input_time_base: ffmpeg.AVRational,
    output_time_base: ffmpeg.AVRational,
    output_stream_index: c_int,
) MuxError!void {
    ffmpeg.av_packet_rescale_ts(
        packet,
        input_time_base,
        output_time_base,
    );
    packet.stream_index = output_stream_index;
    packet.pos = -1;
    const result = ffmpeg.av_interleaved_write_frame(output, packet);
    
    ffmpeg.av_packet_unref(packet);
    
    if (result < 0) {
        return error.PacketWriteFailed;
    }
}