const std = @import("std");
const build_options = @import("build_options");
const app_state = @import("app_state.zig");
const ffmpeg_cli = @import("core/ffmpeg_cli.zig");
const media = @import("core/media.zig");
const stabilizer = @import("core/stabilizer.zig");
const tracker = @import("core/tracker.zig");
const trajectory = @import("core/trajectory.zig");
const engine = @import("engine/engine.zig");
const decoder = engine.decoder;
const engine_types = engine.types;

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

test "preview size is bounded without upscaling" {
    const full_hd = media.fitPreviewSize(1920, 1080, 960, 540);
    try std.testing.expectEqual(@as(u32, 960), full_hd.width);
    try std.testing.expectEqual(@as(u32, 540), full_hd.height);

    const portrait = media.fitPreviewSize(1080, 1920, 960, 540);
    try std.testing.expectEqual(@as(u32, 304), portrait.width);
    try std.testing.expectEqual(@as(u32, 540), portrait.height);

    const small = media.fitPreviewSize(640, 360, 960, 540);
    try std.testing.expectEqual(@as(u32, 640), small.width);
    try std.testing.expectEqual(@as(u32, 360), small.height);
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

test "rejects zero ffprobe frame rate numerator" {
    const output =
        \\width=1920
        \\height=1080
        \\avg_frame_rate=0/1
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

test "analysis sequence preserves frame count and presentation order" {
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 60 };
    var validator = engine_types.SequenceValidator{};

    try validator.push(engine_types.AnalysisRecord.reference(.{
        .index = 0,
        .pts = 0,
        .duration = 1,
        .time_base = time_base,
    }, 0));
    try validator.push(.{
        .timing = .{
            .index = 1,
            .pts = 1,
            .duration = 1,
            .time_base = time_base,
        },
        .global_motion_from_previous = .{ .x = 2, .y = -1, .angle = 0.01 },
        .confidence = 0.9,
        .tracked_points = 100,
        .inlier_points = 84,
        .residual_px = 0.7,
    });
    try validator.finish(2);
}

test "analysis sequence rejects a skipped frame" {
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 30 };
    var validator = engine_types.SequenceValidator{};
    try validator.push(engine_types.AnalysisRecord.reference(.{
        .index = 0,
        .pts = 0,
        .time_base = time_base,
    }, 0));

    try std.testing.expectError(error.UnexpectedFrameIndex, validator.push(.{
        .timing = .{
            .index = 2,
            .pts = 2,
            .time_base = time_base,
        },
        .confidence = 0.8,
    }));
}

test "analysis sequence rejects non-monotonic PTS" {
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 1000 };
    var validator = engine_types.SequenceValidator{};
    try validator.push(engine_types.AnalysisRecord.reference(.{
        .index = 0,
        .pts = 100,
        .time_base = time_base,
    }, 0));

    try std.testing.expectError(error.NonMonotonicPts, validator.push(.{
        .timing = .{
            .index = 1,
            .pts = 100,
            .time_base = time_base,
        },
        .confidence = 0.8,
    }));
}

test "scene cut starts with identity motion and a new scene" {
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 24 };
    var validator = engine_types.SequenceValidator{};
    try validator.push(engine_types.AnalysisRecord.reference(.{
        .index = 0,
        .pts = 0,
        .time_base = time_base,
    }, 0));
    try validator.push(.{
        .timing = .{
            .index = 1,
            .pts = 1,
            .time_base = time_base,
        },
        .confidence = 1,
        .scene_id = 1,
        .flags = .{ .scene_cut = true },
    });
    try validator.finish(2);
}

test "analysis record rejects invalid transform and point counts" {
    const timing = engine_types.FrameTiming{
        .index = 0,
        .pts = 0,
        .time_base = .{ .numerator = 1, .denominator = 30 },
    };
    try std.testing.expectError(error.InvalidTransform, (engine_types.AnalysisRecord{
        .timing = timing,
        .global_motion_from_previous = .{ .scale = 0 },
    }).validate());
    try std.testing.expectError(error.InvalidPointCount, (engine_types.AnalysisRecord{
        .timing = timing,
        .tracked_points = 4,
        .inlier_points = 5,
    }).validate());
}

test "selected engine never falls back silently" {
    switch (engine.selected_backend) {
        .legacy => try engine.ensureSelectedBackendIsReady(),
        .native => if (engine.native_dependencies_enabled)
            try std.testing.expectError(
                error.NativeEngineNotImplemented,
                engine.ensureSelectedBackendIsReady(),
            )
        else
            try std.testing.expectError(
                error.NativeDependenciesDisabled,
                engine.ensureSelectedBackendIsReady(),
            ),
    }
}

test "analysis dimensions preserve aspect ratio without upscaling" {
    const landscape = try decoder.fitAnalysisDimensions(1920, 1080, 960);
    try std.testing.expectEqual(@as(u32, 960), landscape.width);
    try std.testing.expectEqual(@as(u32, 540), landscape.height);

    const portrait = try decoder.fitAnalysisDimensions(1080, 1920, 960);
    try std.testing.expectEqual(@as(u32, 540), portrait.width);
    try std.testing.expectEqual(@as(u32, 960), portrait.height);

    const small = try decoder.fitAnalysisDimensions(640, 360, 960);
    try std.testing.expectEqual(@as(u32, 640), small.width);
    try std.testing.expectEqual(@as(u32, 360), small.height);
}

test "native decoder reports a missing input without leaking ownership" {
    if (!decoder.native_enabled) return error.SkipZigTest;
    try std.testing.expectError(error.OpenInputFailed, decoder.Decoder.open(
        std.testing.allocator,
        "axia-test-input-that-does-not-exist.mp4",
        .{},
    ));
}

test "native decoder visits every frame in an integration fixture" {
    if (!decoder.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0 or build_options.test_video_frames == 0) {
        return error.SkipZigTest;
    }

    var video_decoder = try decoder.Decoder.open(
        std.testing.allocator,
        build_options.test_video,
        .{ .max_analysis_dimension = 160 },
    );
    defer video_decoder.deinit();

    var validator = engine_types.SequenceValidator{};
    var previous_pts: ?i64 = null;
    var first_delta: ?i64 = null;
    var has_variable_delta = false;
    while (try video_decoder.readFrame()) |frame| {
        if (previous_pts) |pts| {
            const delta = frame.timing.pts - pts;
            if (first_delta) |initial_delta| {
                has_variable_delta = has_variable_delta or delta != initial_delta;
            } else {
                first_delta = delta;
            }
        }
        previous_pts = frame.timing.pts;

        const record = if (frame.timing.index == 0)
            engine_types.AnalysisRecord.reference(frame.timing, 0)
        else
            engine_types.AnalysisRecord{
                .timing = frame.timing,
                .confidence = 0,
                .flags = .{ .low_confidence = true, .fallback = true },
            };
        try validator.push(record);
        try std.testing.expectEqual(
            frame.stride * @as(usize, frame.height),
            frame.pixels.len,
        );
    }
    try validator.finish(build_options.test_video_frames);
    if (build_options.test_video_require_vfr) {
        try std.testing.expect(has_variable_delta);
    }
}
