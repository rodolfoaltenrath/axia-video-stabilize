const std = @import("std");
const app_state = @import("app_state.zig");
const ffmpeg_cli = @import("core/ffmpeg_cli.zig");
const media = @import("core/media.zig");
const stabilizer = @import("core/stabilizer.zig");
const tracker = @import("core/tracker.zig");
const trajectory = @import("core/trajectory.zig");

test "accumulates camera motion" {
    const motions = [_]tracker.Motion{
        .{ .dx = 2, .dy = -1, .dtheta = 0.1 },
        .{ .dx = 3, .dy = 4, .dtheta = 0.2 },
    };
    const result = try stabilizer.accumulate(std.testing.allocator, &motions);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(f64, 5), result[1].x);
    try std.testing.expectEqual(@as(f64, 3), result[1].y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result[1].angle, 0.000001);
}

test "moving average preserves constant trajectory" {
    const input = [_]stabilizer.Transform{
        .{ .x = 4, .y = 2, .angle = 0.1 },
        .{ .x = 4, .y = 2, .angle = 0.1 },
        .{ .x = 4, .y = 2, .angle = 0.1 },
    };
    const result = try stabilizer.smooth(std.testing.allocator, &input, 5);
    defer std.testing.allocator.free(result);
    for (result) |sample| {
        try std.testing.expectEqual(@as(f64, 4), sample.x);
        try std.testing.expectEqual(@as(f64, 2), sample.y);
        try std.testing.expectApproxEqAbs(@as(f64, 0.1), sample.angle, 0.000001);
    }
}

test "smoothness maps to a bounded radius" {
    try std.testing.expectEqual(@as(usize, 0), stabilizer.radiusFromSmoothness(0, 30));
    try std.testing.expectEqual(@as(usize, 60), stabilizer.radiusFromSmoothness(100, 30));
}

test "derives stabilized output beside source" {
    var buffer: [256]u8 = undefined;
    const output = try media.deriveOutputPath(&buffer, "C:\\videos\\take.MOV");
    try std.testing.expectEqualStrings("C:\\videos\\take-stabilized.mp4", output);
}

test "rejects unsupported media extension" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedFormat,
        media.deriveOutputPath(&buffer, "C:\\videos\\notes.txt"),
    );
}

test "parses ffprobe metadata" {
    const output =
        \\width=1920
        \\height=1080
        \\avg_frame_rate=30000/1001
        \\nb_frames=240
        \\duration=8.008000
    ;
    const info = try ffmpeg_cli.parseProbeOutput(output);
    try std.testing.expectEqual(@as(u32, 1920), info.width);
    try std.testing.expectEqual(@as(u32, 1080), info.height);
    try std.testing.expectEqual(@as(u64, 240), info.frame_count.?);
    try std.testing.expectApproxEqAbs(@as(f64, 29.97002997), info.framesPerSecond(), 0.000001);
}

test "rejects invalid ffprobe frame rate" {
    const output =
        \\width=1920
        \\height=1080
        \\avg_frame_rate=30/0
        \\duration=8.0
    ;
    try std.testing.expectError(error.InvalidFrameRate, ffmpeg_cli.parseProbeOutput(output));
}

test "estimates frame count when container omits it" {
    const info = ffmpeg_cli.ProbeInfo{
        .width = 1280,
        .height = 720,
        .frame_rate_numerator = 30000,
        .frame_rate_denominator = 1001,
        .duration_seconds = 10.01,
    };
    try std.testing.expectEqual(@as(u64, 300), info.estimatedFrameCount());
}

test "parses ffmpeg frame progress blocks" {
    var parser = ffmpeg_cli.ProgressParser{};
    try std.testing.expect(parser.push("frame=23\r\n") == null);
    try std.testing.expect(parser.push("out_time_us=766667\r\n") == null);
    try std.testing.expect(parser.push("speed=5.47x\r\n") == null);
    const progress = parser.push("progress=continue\r\n").?;

    try std.testing.expectEqual(@as(u64, 23), progress.frame);
    try std.testing.expectEqual(@as(u64, 766667), progress.out_time_us);
    try std.testing.expectApproxEqAbs(@as(f64, 5.47), progress.speed, 0.000001);
    try std.testing.expect(!progress.finished);

    const finished = parser.push("progress=end\r\n").?;
    try std.testing.expect(finished.finished);
}

test "processing job freezes media and parameters" {
    var state = app_state.AppState{};
    try std.testing.expect(state.setMedia(
        "C:\\videos\\take.mp4",
        "C:\\videos\\take-stabilized.mp4",
    ));
    state.setParameters(.{ .smoothness = 65, .crop = 8 });
    const job = state.begin() orelse return error.TestUnexpectedResult;
    state.setParameters(.{ .smoothness = 10, .crop = 2 });

    try std.testing.expectEqual(@as(f32, 65), job.parameters.smoothness);
    try std.testing.expectEqual(@as(f32, 8), job.parameters.crop);
    try std.testing.expectEqualStrings("C:\\videos\\take.mp4", job.media.input());

    state.updateFrameProgress(.analyzing, 0.4, 42, 100, 2.5);
    const snapshot = state.snapshot();
    try std.testing.expectEqual(@as(u64, 42), snapshot.processed_frame);
    try std.testing.expectEqual(@as(?u64, 100), snapshot.total_frames);
    try std.testing.expectEqual(@as(f32, 2.5), snapshot.processing_speed);
}

test "cancellation is accepted only for active processing" {
    var state = app_state.AppState{};
    state.requestCancel();
    try std.testing.expect(!state.snapshot().cancel_requested);

    try std.testing.expect(state.setMedia(
        "C:\\videos\\take.mp4",
        "C:\\videos\\take-stabilized.mp4",
    ));
    _ = state.begin() orelse return error.TestUnexpectedResult;
    state.requestCancel();
    try std.testing.expect(state.snapshot().cancel_requested);
}

test "frame trajectory includes identity pose" {
    const motions = [_]trajectory.RelativeMotion{
        .{ .dx = 2, .dy = -1, .dtheta = 0.1, .scale = 1.02 },
        .{ .dx = 3, .dy = 4, .dtheta = 0.2, .scale = 1.01 },
    };
    const poses = try trajectory.integrate(std.testing.allocator, &motions);
    defer std.testing.allocator.free(poses);

    try std.testing.expectEqual(@as(usize, 3), poses.len);
    try std.testing.expectEqual(@as(f64, 0), poses[0].x);
    try std.testing.expectEqual(@as(f64, 5), poses[2].x);
    try std.testing.expectEqual(@as(f64, 3), poses[2].y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), poses[2].angle, 0.000001);
}

test "scene cut starts an independent trajectory segment" {
    const motions = [_]trajectory.RelativeMotion{
        .{ .dx = 20 },
        .{ .scene_cut = true },
        .{ .dx = 3 },
    };
    const poses = try trajectory.integrate(std.testing.allocator, &motions);
    defer std.testing.allocator.free(poses);

    try std.testing.expectEqual(@as(u32, 0), poses[1].segment);
    try std.testing.expectEqual(@as(u32, 1), poses[2].segment);
    try std.testing.expectEqual(@as(f64, 0), poses[2].x);
    try std.testing.expectEqual(@as(f64, 3), poses[3].x);
}

test "gaussian smoothing does not cross scene cuts" {
    const poses = [_]trajectory.Pose{
        .{ .x = 0, .segment = 0 },
        .{ .x = 0, .segment = 0 },
        .{ .x = 100, .segment = 1 },
        .{ .x = 100, .segment = 1 },
    };
    const smoothed = try trajectory.smooth(std.testing.allocator, &poses, 10);
    defer std.testing.allocator.free(smoothed);

    try std.testing.expectApproxEqAbs(@as(f64, 0), smoothed[1].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), smoothed[2].x, 0.000001);
}

test "low confidence pose has little influence on smoothing" {
    const poses = [_]trajectory.Pose{
        .{ .x = 0, .confidence = 1 },
        .{ .x = 100, .confidence = 0 },
        .{ .x = 0, .confidence = 1 },
    };
    const smoothed = try trajectory.smooth(std.testing.allocator, &poses, 2);
    defer std.testing.allocator.free(smoothed);

    try std.testing.expect(smoothed[1].x < 1);
}

test "frame corrections include inverse scale delta" {
    const raw = [_]trajectory.Pose{
        .{ .x = 4, .y = -2, .angle = 0.2, .log_scale = @log(2.0) },
    };
    const smoothed = [_]trajectory.Pose{.{}};
    const corrections = try trajectory.buildCorrections(std.testing.allocator, &raw, &smoothed);
    defer std.testing.allocator.free(corrections);

    try std.testing.expectEqual(@as(f64, -4), corrections[0].x);
    try std.testing.expectEqual(@as(f64, 2), corrections[0].y);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), corrections[0].angle, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), corrections[0].scale, 0.000001);
}
