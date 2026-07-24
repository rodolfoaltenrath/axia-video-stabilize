const std = @import("std");
const app_state = @import("app_state.zig");
const ffmpeg_cli = @import("core/ffmpeg_cli.zig");
const media = @import("core/media.zig");
const stabilizer = @import("core/stabilizer.zig");
const tracker = @import("core/tracker.zig");

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
}
