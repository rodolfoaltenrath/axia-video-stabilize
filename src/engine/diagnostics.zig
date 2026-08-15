const std = @import("std");
const crop = @import("crop.zig");
const decoder = @import("decoder.zig");
const session = @import("session.zig");
const trajectory = @import("trajectory.zig");
const types = @import("types.zig");

pub const DiagnosticsError = error{
    EmptyPath,
    LengthMismatch,
    InvalidAnalysis,
    WriteFailed,
    PublishFailed,
} || std.mem.Allocator.Error;

const header =
    "frame_index,pts,timestamp_seconds,scene_id,scene_cut,low_confidence," ++
    "fallback,confidence,detected_points,tracked_points,inlier_points," ++
    "residual_px,spatial_coverage,motion_x,motion_y,motion_angle," ++
    "motion_scale,raw_x,raw_y,raw_angle,raw_log_scale,smoothed_x," ++
    "smoothed_y,smoothed_angle,smoothed_log_scale,correction_x," ++
    "correction_y,correction_angle,correction_scale,crop_zoom," ++
    "required_zoom,crop_limited\n";

/// Writes a complete diagnostic report beside the requested destination and
/// only publishes it after every row has been flushed successfully.
pub fn writeCsv(
    allocator: std.mem.Allocator,
    path: []const u8,
    analysis: *const session.Analysis,
) DiagnosticsError!void {
    if (path.len == 0) return error.EmptyPath;
    const frame_count = analysis.records.len;
    if (analysis.raw_trajectory.len != frame_count or
        analysis.smoothed_trajectory.len != frame_count or
        analysis.corrections.len != frame_count or
        analysis.crop_frames.len != frame_count)
    {
        return error.LengthMismatch;
    }

    const temporary_path = try std.fmt.allocPrint(
        allocator,
        "{s}.axia-diagnostics-{x}.tmp",
        .{ path, std.crypto.random.int(u64) },
    );
    defer allocator.free(temporary_path);
    var published = false;
    defer if (!published) deleteFile(temporary_path);

    var file = createFile(temporary_path) catch return error.WriteFailed;
    var file_open = true;
    defer if (file_open) file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    const writer = buffered.writer();
    writer.writeAll(header) catch return error.WriteFailed;

    for (
        analysis.records,
        analysis.raw_trajectory,
        analysis.smoothed_trajectory,
        analysis.corrections,
        analysis.crop_frames,
    ) |record, raw, smoothed, correction, crop_frame| {
        const timestamp = record.timing.presentationSeconds() catch
            return error.InvalidAnalysis;
        writer.print(
            "{d},{d},{d:.9},{d},{},{},{},{d:.6},{d},{d},{d}," ++
                "{d:.6},{d:.6},{d:.9},{d:.9},{d:.12},{d:.9}," ++
                "{d:.9},{d:.9},{d:.12},{d:.12},{d:.9},{d:.9}," ++
                "{d:.12},{d:.12},{d:.9},{d:.9},{d:.12},{d:.9}," ++
                "{d:.9},{d:.9},{}\n",
            .{
                record.timing.index,
                record.timing.pts,
                timestamp,
                record.scene_id,
                record.flags.scene_cut,
                record.flags.low_confidence,
                record.flags.fallback,
                record.confidence,
                record.detected_points,
                record.tracked_points,
                record.inlier_points,
                record.residual_px,
                record.spatial_coverage,
                record.global_motion_from_previous.x,
                record.global_motion_from_previous.y,
                record.global_motion_from_previous.angle,
                record.global_motion_from_previous.scale,
                raw.x,
                raw.y,
                raw.angle,
                raw.log_scale,
                smoothed.x,
                smoothed.y,
                smoothed.angle,
                smoothed.log_scale,
                correction.x,
                correction.y,
                correction.angle,
                correction.scale,
                crop_frame.zoom,
                crop_frame.required_zoom,
                crop_frame.limited,
            },
        ) catch return error.WriteFailed;
    }
    buffered.flush() catch return error.WriteFailed;
    file.sync() catch return error.WriteFailed;
    file.close();
    file_open = false;

    publishFile(temporary_path, path) catch return error.PublishFailed;
    published = true;
}

fn createFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{});
    }
    return std.fs.cwd().createFile(path, .{});
}

fn deleteFile(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn publishFile(source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(source) and
        std.fs.path.isAbsolute(destination))
    {
        try std.fs.renameAbsolute(source, destination);
    } else {
        try std.fs.cwd().rename(source, destination);
    }
}

test "diagnostic CSV contains analysis and stabilization metrics" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", temporary.sub_path[0..] },
    );
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "diagnostics.csv" },
    );
    defer std.testing.allocator.free(path);

    var records = [_]types.AnalysisRecord{.{
        .timing = .{
            .index = 0,
            .pts = 15,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        },
        .confidence = 0.75,
        .detected_points = 80,
        .tracked_points = 64,
        .inlier_points = 60,
        .residual_px = 0.4,
        .spatial_coverage = 0.8,
    }};
    var raw = [_]trajectory.Pose{.{ .x = 2, .timestamp_seconds = 0.5 }};
    var smoothed = [_]trajectory.Pose{.{ .x = 1, .timestamp_seconds = 0.5 }};
    var corrections = [_]trajectory.Correction{.{ .x = -1 }};
    var crop_frames = [_]crop.Frame{.{
        .zoom = 1.1,
        .required_zoom = 1.05,
        .limited = false,
    }};
    const analysis = session.Analysis{
        .allocator = std.testing.allocator,
        .video_info = decoder.VideoInfo{
            .source = .{ .width = 1920, .height = 1080 },
            .analysis = .{ .width = 960, .height = 540 },
            .color = .{},
            .time_base = .{ .numerator = 1, .denominator = 30 },
            .frame_rate = .{ .numerator = 30, .denominator = 1 },
            .duration_seconds = 1,
            .estimated_frame_count = 1,
        },
        .records = &records,
        .raw_trajectory = &raw,
        .smoothed_trajectory = &smoothed,
        .corrections = &corrections,
        .crop_frames = &crop_frames,
    };

    try writeCsv(std.testing.allocator, path, &analysis);
    const contents = try temporary.dir.readFileAlloc(
        std.testing.allocator,
        "diagnostics.csv",
        16 * 1024,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.startsWith(u8, contents, header));
    try std.testing.expect(std.mem.indexOf(
        u8,
        contents,
        "0,15,0.500000000,0,false,false,false,0.750000,80,64,60",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        contents,
        ",-1.000000000,0.000000000,0.000000000000,1.000000000," ++
            "1.100000000,1.050000000,false\n",
    ) != null);
}

test "diagnostic CSV rejects inconsistent analysis lengths" {
    var records: [1]types.AnalysisRecord = undefined;
    var raw: [0]trajectory.Pose = .{};
    var smoothed: [0]trajectory.Pose = .{};
    var corrections: [0]trajectory.Correction = .{};
    var crop_frames: [0]crop.Frame = .{};
    const analysis = session.Analysis{
        .allocator = std.testing.allocator,
        .video_info = undefined,
        .records = &records,
        .raw_trajectory = &raw,
        .smoothed_trajectory = &smoothed,
        .corrections = &corrections,
        .crop_frames = &crop_frames,
    };
    try std.testing.expectError(
        error.LengthMismatch,
        writeCsv(std.testing.allocator, "unused.csv", &analysis),
    );
}
