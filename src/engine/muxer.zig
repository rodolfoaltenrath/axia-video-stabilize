const std = @import("std");
const build_options = @import("build_options");

const ffmpeg = if (build_options.native_ffmpeg) @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
}) else struct {};

pub const native_enabled = build_options.native_ffmpeg;

pub const Progress = struct {
    processed_packets: u64,
    processed_seconds: f64,
    total_seconds: ?f64,

    pub fn ratio(self: Progress) ?f32 {
        const total = self.total_seconds orelse return null;
        if (!std.math.isFinite(self.processed_seconds) or
            !std.math.isFinite(total) or total <= 0)
        {
            return null;
        }
        return @floatCast(std.math.clamp(
            self.processed_seconds / total,
            0,
            1,
        ));
    }
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
    copy_metadata: bool = true,
    require_audio: bool = false,
    faststart: bool = true,
    observer: Observer = .{},
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
    Cancelled,
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
        if (options.observer.isCancelled()) return error.Cancelled;

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
        if (options.observer.isCancelled()) return error.Cancelled;

        const total_duration_seconds = maximumDurationSeconds(
            inputDurationSeconds(video_input),
            inputDurationSeconds(source_input),
        );

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
        var io_observer = options.observer;
        output.interrupt_callback = .{
            .callback = interruptIo,
            .@"opaque" = &io_observer,
        };

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

                // Modern FFmpeg stores display metadata in codec parameters.
                // Use exactly one representation: recent FFmpeg still exposes
                // the deprecated AVStream fields, but populating both makes the
                // muxer alias the same display matrix and later free it twice.
                if (@hasField(ffmpeg.AVCodecParameters, "nb_coded_side_data") and @hasDecl(ffmpeg, "av_packet_side_data_new")) {
                    const nb_side: usize = @intCast(source_video.*.codecpar.*.nb_coded_side_data);
                    for (0..nb_side) |i| {
                        const sd = source_video.*.codecpar.*.coded_side_data[i];
                        if (sd.type == ffmpeg.AV_PKT_DATA_DISPLAYMATRIX) {
                            const destination_side_data = ffmpeg.av_packet_side_data_new(
                                &output_video_stream.*.codecpar.*.coded_side_data,
                                &output_video_stream.*.codecpar.*.nb_coded_side_data,
                                sd.type,
                                sd.size,
                                0,
                            ) orelse return error.MetadataCopyFailed;
                            const size: usize = @intCast(sd.size);
                            @memcpy(
                                destination_side_data.*.data[0..size],
                                sd.data[0..size],
                            );
                        }
                    }
                } else if (@hasField(ffmpeg.AVStream, "nb_side_data") and @hasDecl(ffmpeg, "av_stream_new_side_data")) {
                    // Compatibility path for FFmpeg versions predating coded
                    // side data in AVCodecParameters.
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
            }
        }

        var io_open = false;
        errdefer if (io_open) {
            _ = ffmpeg.avio_closep(&output.pb);
        };
        if ((output.oformat.*.flags & ffmpeg.AVFMT_NOFILE) == 0) {
            if (ffmpeg.avio_open2(
                &output.pb,
                output_path_z.ptr,
                ffmpeg.AVIO_FLAG_WRITE,
                &output.interrupt_callback,
                null,
            ) < 0) {
                if (options.observer.isCancelled()) return error.Cancelled;
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
            if (options.observer.isCancelled()) return error.Cancelled;
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
        var processed_packets: u64 = 0;
        var processed_seconds: f64 = 0;
        options.observer.report(.{
            .processed_packets = 0,
            .processed_seconds = 0,
            .total_seconds = total_duration_seconds,
        });
        while (!video_eof or !audio_eof or video_ready or audio_ready) {
            if (options.observer.isCancelled()) return error.Cancelled;
            if (!video_ready and !video_eof) {
                video_ready = try readNextVideoPacket(
                    video_input,
                    video_stream_index,
                    video_packet,
                    &video_eof,
                    options.observer,
                );
            }
            if (!audio_ready and !audio_eof) {
                audio_ready = try readNextAudioPacket(
                    source_input,
                    stream_mapping,
                    audio_packet,
                    &audio_eof,
                    options.observer,
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
                if (packetPositionSeconds(
                    video_packet,
                    input_video_stream.*.time_base,
                    video_input.start_time,
                )) |position| {
                    processed_seconds = @max(processed_seconds, position);
                }
                try writePacket(
                    output,
                    video_packet,
                    input_video_stream.*.time_base,
                    output_video_stream.*.time_base,
                    output_video_stream.*.index,
                    options.observer,
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
                if (packetPositionSeconds(
                    audio_packet,
                    source_input.streams[source_index].*.time_base,
                    source_input.start_time,
                )) |position| {
                    processed_seconds = @max(processed_seconds, position);
                }
                try writePacket(
                    output,
                    audio_packet,
                    source_input.streams[source_index].*.time_base,
                    output_stream.*.time_base,
                    output_index,
                    options.observer,
                );
                audio_ready = false;
            }
            processed_packets += 1;
            if (processed_packets % 32 == 0) {
                options.observer.report(.{
                    .processed_packets = processed_packets,
                    .processed_seconds = processed_seconds,
                    .total_seconds = total_duration_seconds,
                });
            }
        }

        if (options.observer.isCancelled()) return error.Cancelled;
        if (ffmpeg.av_write_trailer(output) < 0) {
            if (options.observer.isCancelled()) return error.Cancelled;
            return error.TrailerWriteFailed;
        }
        if (io_open) {
            _ = ffmpeg.avio_closep(&output.pb);
            io_open = false;
        }
        ffmpeg.avformat_free_context(output);
        options.observer.report(.{
            .processed_packets = processed_packets,
            .processed_seconds = total_duration_seconds orelse
                processed_seconds,
            .total_seconds = total_duration_seconds,
        });
        return .{ .audio_streams = audio_stream_count };
    }
};

fn inputDurationSeconds(context: *const ffmpeg.AVFormatContext) ?f64 {
    if (context.duration <= 0 or context.duration == ffmpeg.AV_NOPTS_VALUE) {
        return null;
    }
    const seconds = @as(f64, @floatFromInt(context.duration)) /
        @as(f64, ffmpeg.AV_TIME_BASE);
    return if (std.math.isFinite(seconds) and seconds > 0)
        seconds
    else
        null;
}

fn maximumDurationSeconds(left: ?f64, right: ?f64) ?f64 {
    if (left) |left_value| {
        if (right) |right_value| return @max(left_value, right_value);
        return left_value;
    }
    return right;
}

fn packetPositionSeconds(
    packet: *const ffmpeg.AVPacket,
    time_base: ffmpeg.AVRational,
    input_start_time: i64,
) ?f64 {
    if (time_base.num <= 0 or time_base.den <= 0) return null;
    const timestamp = packetTimestamp(packet);
    if (timestamp == ffmpeg.AV_NOPTS_VALUE) return null;

    const duration = @max(packet.duration, 0);
    var seconds = (@as(f64, @floatFromInt(timestamp)) +
        @as(f64, @floatFromInt(duration))) *
        @as(f64, @floatFromInt(time_base.num)) /
        @as(f64, @floatFromInt(time_base.den));
    if (input_start_time != ffmpeg.AV_NOPTS_VALUE) {
        seconds -= @as(f64, @floatFromInt(input_start_time)) /
            @as(f64, ffmpeg.AV_TIME_BASE);
    }
    if (!std.math.isFinite(seconds)) return null;
    return @max(0, seconds);
}

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
    observer: Observer,
) MuxError!bool {
    while (true) {
        if (observer.isCancelled()) return error.Cancelled;
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
    observer: Observer,
) MuxError!bool {
    while (true) {
        if (observer.isCancelled()) return error.Cancelled;
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
    observer: Observer,
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
        if (observer.isCancelled()) return error.Cancelled;
        return error.PacketWriteFailed;
    }
}

fn interruptIo(raw_context: ?*anyopaque) callconv(.C) c_int {
    const observer: *const Observer = @ptrCast(@alignCast(raw_context.?));
    return if (observer.isCancelled()) 1 else 0;
}

fn testCancellation(raw_context: ?*anyopaque) bool {
    const cancelled: *const bool = @ptrCast(@alignCast(raw_context.?));
    return cancelled.*;
}

test "mux progress ratio is bounded and requires a duration" {
    try std.testing.expectEqual(
        @as(?f32, null),
        (Progress{
            .processed_packets = 10,
            .processed_seconds = 2,
            .total_seconds = null,
        }).ratio(),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.25),
        (Progress{
            .processed_packets = 10,
            .processed_seconds = 2,
            .total_seconds = 8,
        }).ratio().?,
        0.000001,
    );
    try std.testing.expectEqual(
        @as(f32, 1),
        (Progress{
            .processed_packets = 10,
            .processed_seconds = 12,
            .total_seconds = 8,
        }).ratio().?,
    );
}

test "mux observer exposes cancellation state" {
    var cancelled = false;
    const observer = Observer{
        .context = &cancelled,
        .should_cancel = testCancellation,
    };
    try std.testing.expect(!observer.isCancelled());
    cancelled = true;
    try std.testing.expect(observer.isCancelled());
}
