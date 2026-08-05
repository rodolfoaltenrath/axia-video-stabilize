const std = @import("std");
const build_options = @import("build_options");
const app_state = @import("app_state.zig");
const media = @import("core/media.zig");
const file_dialog = @import("platform/file_dialog.zig");
const engine = @import("engine/engine.zig");
const analyzer = engine.analyzer;
const crop = engine.crop;
const decoder = engine.decoder;
const encoder = engine.encoder;
const exporter = engine.exporter;
const features = engine.features;
const engine_types = engine.types;
const motion = engine.motion;
const muxer = engine.muxer;
const renderer = engine.renderer;
const session = engine.session;
const trajectory = engine.trajectory;
const warp = engine.warp;

comptime {
    _ = file_dialog;
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

test "processing job freezes media and parameters" {
    var state = app_state.AppState{};
    try std.testing.expect(state.setMedia(
        "C:\\videos\\take.mp4",
        "C:\\videos\\take-stabilized.mp4",
    ));
    state.setParameters(.{
        .smoothness = 65,
        .crop = 8,
        .export_quality = .high,
    });
    const job = state.begin() orelse return error.TestUnexpectedResult;
    state.setParameters(.{ .smoothness = 10, .crop = 2 });

    try std.testing.expectEqual(@as(f32, 65), job.parameters.smoothness);
    try std.testing.expectEqual(@as(f32, 8), job.parameters.crop);
    try std.testing.expectEqual(
        app_state.ExportQuality.high,
        job.parameters.export_quality,
    );
    try std.testing.expectEqualStrings("C:\\videos\\take.mp4", job.media.input());

    state.updateFrameProgress(.analyzing, 0.4, 42, 100, 2.5);
    const snapshot = state.snapshot();
    try std.testing.expectEqual(@as(u64, 42), snapshot.processed_frame);
    try std.testing.expectEqual(@as(?u64, 100), snapshot.total_frames);
    try std.testing.expectEqual(@as(f32, 2.5), snapshot.processing_speed);
}

test "export quality presets map to encoder settings" {
    const high = app_state.ExportQuality.high.encoderProfile();
    const balanced = app_state.ExportQuality.balanced.encoderProfile();
    const compact = app_state.ExportQuality.compact.encoderProfile();

    try std.testing.expectEqual(@as(u8, 16), high.crf);
    try std.testing.expectEqualStrings("slow", high.preset);
    try std.testing.expectEqual(@as(u8, 18), balanced.crf);
    try std.testing.expectEqualStrings("medium", balanced.preset);
    try std.testing.expectEqual(@as(u8, 24), compact.crf);
    try std.testing.expectEqualStrings("fast", compact.preset);
}

test "muxing remains an active cancellable phase" {
    var state = app_state.AppState{};
    try std.testing.expect(state.setMedia(
        "C:\\videos\\take.mp4",
        "C:\\videos\\take-stabilized.mp4",
    ));
    _ = state.begin() orelse return error.TestUnexpectedResult;
    state.update(.muxing, 0.98);
    state.requestCancel();

    const snapshot = state.snapshot();
    try std.testing.expect(snapshot.phase.isBusy());
    try std.testing.expect(snapshot.cancel_requested);
    try std.testing.expectEqualStrings(
        "Finalizando áudio e contêiner",
        snapshot.phase.label(),
    );
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
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 10 };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 2, .y = -1 },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 2, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 3, .y = 4 },
            .confidence = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectEqual(@as(usize, 3), poses.len);
    try std.testing.expectEqual(@as(f64, 0), poses[0].x);
    try std.testing.expectEqual(@as(f64, 5), poses[2].x);
    try std.testing.expectEqual(@as(f64, 3), poses[2].y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), poses[2].timestamp_seconds, 0.000001);
}

test "scene cut starts an independent trajectory segment" {
    const time_base = engine_types.Rational{ .numerator = 1, .denominator = 24 };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 20 },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 2, .time_base = time_base },
            .confidence = 1,
            .scene_id = 1,
            .flags = .{ .scene_cut = true },
        },
        .{
            .timing = .{ .index = 3, .pts = 3, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 3 },
            .confidence = 1,
            .scene_id = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectEqual(@as(u32, 0), poses[1].segment);
    try std.testing.expectEqual(@as(u32, 1), poses[2].segment);
    try std.testing.expectEqual(@as(f64, 0), poses[2].x);
    try std.testing.expectEqual(@as(f64, 3), poses[3].x);
}

test "low confidence motion does not contaminate later poses" {
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        }, 0),
        .{
            .timing = .{
                .index = 1,
                .pts = 1,
                .time_base = .{ .numerator = 1, .denominator = 30 },
            },
            .global_motion_from_previous = .{ .x = 100, .y = -50 },
            .confidence = 0.1,
            .flags = .{ .low_confidence = true },
        },
        .{
            .timing = .{
                .index = 2,
                .pts = 2,
                .time_base = .{ .numerator = 1, .denominator = 30 },
            },
            .global_motion_from_previous = .{ .x = 2, .y = 1 },
            .confidence = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 0), poses[1].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), poses[1].y, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), poses[2].y, 0.000001);
}

test "short low confidence gap is reconstructed using VFR timing" {
    const time_base = engine_types.Rational{
        .numerator = 1,
        .denominator = 1000,
    };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 100, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 1 },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 300, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 100 },
            .confidence = 0,
            .flags = .{ .low_confidence = true, .fallback = true },
        },
        .{
            .timing = .{ .index = 3, .pts = 400, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 1 },
            .confidence = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 1), poses[1].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 4), poses[3].x, 0.000001);
}

test "short motion gap interpolates rotation and logarithmic scale" {
    const time_base = engine_types.Rational{
        .numerator = 1,
        .denominator = 1,
    };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
            .global_motion_from_previous = .{
                .angle = 0.1,
                .scale = @exp(0.02),
            },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 2, .time_base = time_base },
            .confidence = 0,
            .flags = .{ .low_confidence = true, .fallback = true },
        },
        .{
            .timing = .{ .index = 3, .pts = 3, .time_base = time_base },
            .global_motion_from_previous = .{
                .angle = 0.3,
                .scale = @exp(0.06),
            },
            .confidence = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 0.3), poses[2].angle, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), poses[2].log_scale, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), poses[3].angle, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), poses[3].log_scale, 0.000001);
}

test "motion gap reconstruction does not cross scene cuts" {
    const time_base = engine_types.Rational{
        .numerator = 1,
        .denominator = 30,
    };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 2 },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 2, .time_base = time_base },
            .confidence = 0,
            .flags = .{ .low_confidence = true, .fallback = true },
        },
        .{
            .timing = .{ .index = 3, .pts = 3, .time_base = time_base },
            .confidence = 1,
            .scene_id = 1,
            .flags = .{ .scene_cut = true },
        },
        .{
            .timing = .{ .index = 4, .pts = 4, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 8 },
            .confidence = 1,
            .scene_id = 1,
        },
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), poses[3].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 8), poses[4].x, 0.000001);
}

test "long motion gaps remain identity" {
    const time_base = engine_types.Rational{
        .numerator = 1,
        .denominator = 30,
    };
    var records: [7]engine_types.AnalysisRecord = undefined;
    records[0] = engine_types.AnalysisRecord.reference(.{
        .index = 0,
        .pts = 0,
        .time_base = time_base,
    }, 0);
    records[1] = .{
        .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
        .global_motion_from_previous = .{ .x = 2 },
        .confidence = 1,
    };
    for (2..6) |index| {
        records[index] = .{
            .timing = .{
                .index = @intCast(index),
                .pts = @intCast(index),
                .time_base = time_base,
            },
            .confidence = 0,
            .flags = .{ .low_confidence = true, .fallback = true },
        };
    }
    records[6] = .{
        .timing = .{ .index = 6, .pts = 6, .time_base = time_base },
        .global_motion_from_previous = .{ .x = 4 },
        .confidence = 1,
    };
    const poses = try trajectory.integrateAnalysis(
        std.testing.allocator,
        &records,
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[5].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 6), poses[6].x, 0.000001);
}

test "motion gap reconstruction respects acceleration limits" {
    const time_base = engine_types.Rational{
        .numerator = 1,
        .denominator = 1,
    };
    const records = [_]engine_types.AnalysisRecord{
        engine_types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = time_base,
        }, 0),
        .{
            .timing = .{ .index = 1, .pts = 1, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 2 },
            .confidence = 1,
        },
        .{
            .timing = .{ .index = 2, .pts = 2, .time_base = time_base },
            .confidence = 0,
            .flags = .{ .low_confidence = true, .fallback = true },
        },
        .{
            .timing = .{ .index = 3, .pts = 3, .time_base = time_base },
            .global_motion_from_previous = .{ .x = 10 },
            .confidence = 1,
        },
    };
    const poses = try trajectory.integrateAnalysisWithOptions(
        std.testing.allocator,
        &records,
        .{ .maximum_translation_acceleration = 1 },
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 12), poses[3].x, 0.000001);
}

test "motion gap reconstruction rejects invalid limits" {
    try std.testing.expectError(
        error.InvalidIntegrationOptions,
        trajectory.integrateAnalysisWithOptions(
            std.testing.allocator,
            &.{},
            .{ .maximum_rotation_acceleration = std.math.nan(f64) },
        ),
    );
}

test "gaussian smoothing does not cross scene cuts" {
    const poses = [_]trajectory.Pose{
        .{ .x = 0, .segment = 0, .timestamp_seconds = 0 },
        .{ .x = 0, .segment = 0, .timestamp_seconds = 0.1 },
        .{ .x = 100, .segment = 1, .timestamp_seconds = 0.2 },
        .{ .x = 100, .segment = 1, .timestamp_seconds = 0.3 },
    };
    const smoothed = try trajectory.smoothTimed(std.testing.allocator, &poses, 10);
    defer std.testing.allocator.free(smoothed);

    try std.testing.expectApproxEqAbs(@as(f64, 0), smoothed[1].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), smoothed[2].x, 0.000001);
}

test "low confidence pose has little influence on smoothing" {
    const poses = [_]trajectory.Pose{
        .{ .x = 0, .confidence = 1, .timestamp_seconds = 0 },
        .{ .x = 100, .confidence = 0, .timestamp_seconds = 1 },
        .{ .x = 0, .confidence = 1, .timestamp_seconds = 2 },
    };
    const smoothed = try trajectory.smoothTimed(std.testing.allocator, &poses, 2);
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

    try std.testing.expectApproxEqAbs(
        @as(f64, -1.7614638249),
        corrections[0].x,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.3774052394),
        corrections[0].y,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), corrections[0].angle, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), corrections[0].scale, 0.000001);
}

test "native trajectory uses presentation time for VFR smoothing" {
    const poses = [_]trajectory.Pose{
        .{ .x = 0, .timestamp_seconds = 0 },
        .{ .x = 10, .timestamp_seconds = 0.1 },
        .{ .x = 100, .timestamp_seconds = 4.0 },
    };
    const smoothed = try trajectory.smoothTimed(
        std.testing.allocator,
        &poses,
        0.5,
    );
    defer std.testing.allocator.free(smoothed);

    try std.testing.expect(smoothed[0].x > 0);
    try std.testing.expect(smoothed[0].x < 10);
    try std.testing.expectApproxEqAbs(
        @as(f64, 100),
        smoothed[2].x,
        0.000001,
    );
}

test "affine render matrix round-trips a point" {
    const matrix = try warp.matrixFromCorrection(
        .{ .x = 4, .y = -3, .angle = 0.12, .scale = 1.02 },
        1.1,
        1920,
        1080,
    );
    const source = warp.Point{ .x = 613.25, .y = 417.75 };
    const rendered = matrix.apply(source);
    const recovered = try matrix.inverseMap(rendered);
    try std.testing.expectApproxEqAbs(source.x, recovered.x, 0.000001);
    try std.testing.expectApproxEqAbs(source.y, recovered.y, 0.000001);
}

test "crop planner finds minimum zoom for translation" {
    const requirement = try crop.requiredZoom(
        .{ .x = 10 },
        100,
        100,
        .{ .max_zoom = 2 },
    );
    try std.testing.expect(!requirement.limited);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.2531645569),
        requirement.zoom,
        0.000001,
    );
}

test "crop constraint attenuates an unsafe correction" {
    const options = crop.Options{
        .max_zoom = 1.2,
        .search_iterations = 48,
    };
    const original = trajectory.Correction{ .x = 80, .y = -45 };
    const constrained = try crop.constrainCorrection(
        original,
        320,
        180,
        options,
    );
    const requirement = try crop.requiredZoom(
        constrained,
        320,
        180,
        options,
    );

    try std.testing.expect(@abs(constrained.x) < @abs(original.x));
    try std.testing.expect(@abs(constrained.y) < @abs(original.y));
    try std.testing.expect(!requirement.limited);
    try std.testing.expect(requirement.zoom <= options.max_zoom);
}

test "crop constraint changes stabilization strength gradually" {
    const original = [_]trajectory.Correction{
        .{ .x = 40 },
        .{ .x = 40 },
        .{ .x = 160 },
        .{ .x = 40 },
        .{ .x = 40 },
    };
    var constrained = original;
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0.0 },
        .{ .timestamp_seconds = 0.1 },
        .{ .timestamp_seconds = 0.2 },
        .{ .timestamp_seconds = 0.3 },
        .{ .timestamp_seconds = 0.4 },
    };
    const options = crop.Options{
        .max_zoom = 1.5,
        .correction_strength_rate_per_second = 2,
        .search_iterations = 48,
    };
    try crop.constrainCorrections(
        std.testing.allocator,
        &constrained,
        &poses,
        320,
        180,
        options,
    );

    var previous_strength = constrained[0].x / original[0].x;
    for (constrained[1..], original[1..]) |adjusted, input| {
        const strength = adjusted.x / input.x;
        try std.testing.expect(@abs(strength - previous_strength) <= 0.200001);
        previous_strength = strength;
        const requirement = try crop.requiredZoom(
            adjusted,
            320,
            180,
            options,
        );
        try std.testing.expect(!requirement.limited);
    }
    try std.testing.expect(constrained[1].x < original[1].x);
    try std.testing.expect(constrained[3].x < original[3].x);
}

test "crop constraint does not smooth across scene cuts" {
    const original = [_]trajectory.Correction{
        .{ .x = 40 },
        .{ .x = 40 },
        .{ .x = 160 },
    };
    var constrained = original;
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0.0, .segment = 0 },
        .{ .timestamp_seconds = 0.1, .segment = 0 },
        .{ .timestamp_seconds = 0.2, .segment = 1 },
    };
    try crop.constrainCorrections(
        std.testing.allocator,
        &constrained,
        &poses,
        320,
        180,
        .{ .max_zoom = 1.5, .search_iterations = 48 },
    );

    try std.testing.expectApproxEqAbs(
        original[1].x,
        constrained[1].x,
        0.000001,
    );
    try std.testing.expect(constrained[2].x < original[2].x);
}

test "dynamic crop anticipates motion without crossing scenes" {
    const corrections = [_]trajectory.Correction{
        .{},
        .{ .x = 10 },
        .{},
        .{},
        .{},
    };
    const poses = [_]trajectory.Pose{
        .{ .timestamp_seconds = 0, .segment = 0 },
        .{ .timestamp_seconds = 0.1, .segment = 0 },
        .{ .timestamp_seconds = 0.2, .segment = 0 },
        .{ .timestamp_seconds = 0.3, .segment = 1 },
        .{ .timestamp_seconds = 0.4, .segment = 1 },
    };
    const frames = try crop.plan(
        std.testing.allocator,
        &corrections,
        &poses,
        100,
        100,
        .{
            .max_zoom = 2,
            .dynamic_window_seconds = 0.11,
        },
    );
    defer std.testing.allocator.free(frames);

    try std.testing.expect(frames[0].zoom > 1.25);
    try std.testing.expectApproxEqAbs(frames[0].zoom, frames[1].zoom, 0.000001);
    try std.testing.expectApproxEqAbs(frames[1].zoom, frames[2].zoom, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), frames[3].zoom, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), frames[4].zoom, 0.000001);
}

test "disabled native session fails explicitly" {
    if (session.native_enabled) return error.SkipZigTest;
    try std.testing.expectError(
        error.BackendNotEnabled,
        session.Session.run(
            std.testing.allocator,
            "video.mp4",
            .{},
        ),
    );
}

test "disabled native renderer fails explicitly" {
    if (renderer.native_enabled) return error.SkipZigTest;
    const empty_analysis: *const session.Analysis = undefined;
    try std.testing.expectError(
        error.BackendNotEnabled,
        renderer.Renderer.run(
            std.testing.allocator,
            "video.mp4",
            empty_analysis,
            .{},
        ),
    );
}

test "disabled native encoder fails explicitly" {
    if (encoder.native_enabled) return error.SkipZigTest;
    try std.testing.expectError(
        error.BackendNotEnabled,
        encoder.Encoder.create(
            std.testing.allocator,
            "output.mp4",
            .{ .width = 320, .height = 180 },
            .{ .numerator = 1, .denominator = 30 },
            .{ .numerator = 30, .denominator = 1 },
            .{},
            .{},
        ),
    );
}

test "disabled native muxer fails explicitly" {
    if (muxer.native_enabled) return error.SkipZigTest;
    try std.testing.expectError(
        error.BackendNotEnabled,
        muxer.Muxer.run(
            std.testing.allocator,
            "video.mp4",
            "source.mp4",
            "output.mp4",
            .{},
        ),
    );
}

test "disabled native exporter fails explicitly" {
    if (exporter.native_enabled) return error.SkipZigTest;
    try std.testing.expectError(
        error.BackendNotEnabled,
        exporter.Exporter.run(
            std.testing.allocator,
            "input.mp4",
            "output.mp4",
            .{},
        ),
    );
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
        .detected_points = 120,
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
        .detected_points = 4,
        .tracked_points = 4,
        .inlier_points = 5,
    }).validate());
    try std.testing.expectError(error.InvalidSpatialCoverage, (engine_types.AnalysisRecord{
        .timing = timing,
        .spatial_coverage = 1.1,
    }).validate());
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

test "decoder pixel formats report their storage width" {
    try std.testing.expectEqual(
        @as(usize, 1),
        decoder.PixelFormat.gray8.bytesPerPixel(),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        decoder.PixelFormat.bgra8.bytesPerPixel(),
    );
}

test "decoder color metadata rejects negative identifiers" {
    try std.testing.expect((decoder.ColorInfo{}).isValid());
    try std.testing.expect(!(decoder.ColorInfo{ .matrix = -1 }).isValid());
}

test "feature grid covers non-divisible image dimensions exactly" {
    const options = features.Options{
        .grid_columns = 3,
        .grid_rows = 2,
        .max_per_cell = 5,
    };

    const first = try features.gridCell(101, 55, options, 0, 0);
    const middle = try features.gridCell(101, 55, options, 1, 0);
    const last = try features.gridCell(101, 55, options, 2, 1);

    try std.testing.expectEqual(@as(usize, 0), first.x);
    try std.testing.expectEqual(@as(usize, 33), first.width);
    try std.testing.expectEqual(@as(usize, 33), middle.x);
    try std.testing.expectEqual(@as(usize, 34), middle.width);
    try std.testing.expectEqual(@as(usize, 67), last.x);
    try std.testing.expectEqual(@as(usize, 34), last.width);
    try std.testing.expectEqual(@as(usize, 27), last.y);
    try std.testing.expectEqual(@as(usize, 28), last.height);
    try std.testing.expectEqual(@as(usize, 30), try features.requiredCapacity(options));
}

test "feature options reject an unbounded grid" {
    try std.testing.expectError(
        error.InvalidOptions,
        features.requiredCapacity(.{ .grid_columns = 0 }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        features.requiredCapacity(.{ .quality_level = 1.1 }),
    );
}

test "native Shi-Tomasi detector preserves spatial coverage" {
    if (!features.native_enabled) return error.SkipZigTest;

    const width = 120;
    const height = 90;
    const options = features.Options{
        .grid_columns = 4,
        .grid_rows = 3,
        .max_per_cell = 8,
        .quality_level = 0.01,
        .min_distance = 2,
        .block_size = 3,
        .border = 0,
    };
    var image = [_]u8{0} ** (width * height);

    // One high-contrast square per cell provides four known corners while
    // leaving the detector free to choose their precise subpixel ordering.
    for (0..@as(usize, options.grid_rows)) |row| {
        for (0..@as(usize, options.grid_columns)) |column| {
            const cell = try features.gridCell(width, height, options, column, row);
            const left = cell.x + cell.width / 2 - 5;
            const top = cell.y + cell.height / 2 - 5;
            for (top..top + 10) |y| {
                @memset(image[y * width + left .. y * width + left + 10], 255);
            }
        }
    }

    var storage: [96]features.Point = undefined;
    const points = try features.detectDistributed(
        &image,
        width,
        height,
        width,
        &storage,
        options,
    );
    try std.testing.expect(points.len >= 4 * 3);

    var occupied = [_]bool{false} ** 12;
    for (points) |point| {
        const column = @min(
            @as(usize, @intFromFloat(point.x)) * options.grid_columns / width,
            @as(usize, options.grid_columns - 1),
        );
        const row = @min(
            @as(usize, @intFromFloat(point.y)) * options.grid_rows / height,
            @as(usize, options.grid_rows - 1),
        );
        occupied[row * options.grid_columns + column] = true;
    }
    for (occupied) |has_corner| try std.testing.expect(has_corner);
}

test "native motion estimator recovers a synthetic translation" {
    if (!motion.native_enabled) return error.SkipZigTest;

    const width = 160;
    const height = 120;
    var previous = [_]u8{0} ** (width * height);
    var current = [_]u8{0} ** (width * height);
    const shift_x = 3;
    const shift_y = 2;
    for (0..4) |row| {
        for (0..5) |column| {
            const left = 12 + column * 30;
            const top = 12 + row * 27;
            for (0..7) |square_y| {
                @memset(
                    previous[(top + square_y) * width + left .. (top + square_y) * width + left + 7],
                    255,
                );
                @memset(
                    current[(top + shift_y + square_y) * width +
                        left + shift_x .. (top + shift_y + square_y) * width +
                        left + shift_x + 7],
                    255,
                );
            }
        }
    }

    var estimator = try motion.Estimator.init(std.testing.allocator, .{
        .features = .{
            .grid_columns = 4,
            .grid_rows = 3,
            .max_per_cell = 16,
            .min_distance = 3,
            .border = 0,
        },
        .minimum_tracks = 12,
    });
    defer estimator.deinit();
    const estimate = try estimator.estimate(
        .{
            .pixels = &previous,
            .width = width,
            .height = height,
            .stride = width,
        },
        .{
            .pixels = &current,
            .width = width,
            .height = height,
            .stride = width,
        },
    );

    try std.testing.expectApproxEqAbs(
        @as(f64, shift_x),
        estimate.transform.x,
        0.35,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, shift_y),
        estimate.transform.y,
        0.35,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        estimate.transform.angle,
        0.01,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        estimate.transform.scale,
        0.01,
    );
    try std.testing.expect(estimate.inlier_points >= 12);
    try std.testing.expect(estimate.spatial_coverage > 0.5);
}

test "native motion estimator distrusts motion confined to a small region" {
    if (!motion.native_enabled) return error.SkipZigTest;

    const width = 160;
    const height = 120;
    var previous = [_]u8{0} ** (width * height);
    var current = [_]u8{0} ** (width * height);
    const origin_x = 62;
    const origin_y = 42;
    const shift_x = 3;
    const shift_y = 2;
    for (0..5) |row| {
        for (0..5) |column| {
            const left = origin_x + column * 7;
            const top = origin_y + row * 7;
            for (0..4) |square_y| {
                @memset(
                    previous[(top + square_y) * width + left .. (top + square_y) * width + left + 4],
                    255,
                );
                @memset(
                    current[(top + shift_y + square_y) * width +
                        left + shift_x .. (top + shift_y + square_y) * width +
                        left + shift_x + 4],
                    255,
                );
            }
        }
    }

    var estimator = try motion.Estimator.init(std.testing.allocator, .{
        .features = .{
            .grid_columns = 4,
            .grid_rows = 3,
            .max_per_cell = 20,
            .min_distance = 2,
            .border = 0,
        },
        .minimum_tracks = 8,
    });
    defer estimator.deinit();
    const estimate = try estimator.estimate(
        .{
            .pixels = &previous,
            .width = width,
            .height = height,
            .stride = width,
        },
        .{
            .pixels = &current,
            .width = width,
            .height = height,
            .stride = width,
        },
    );

    try std.testing.expectApproxEqAbs(
        @as(f64, shift_x),
        estimate.transform.x,
        0.35,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, shift_y),
        estimate.transform.y,
        0.35,
    );
    try std.testing.expect(estimate.spatial_coverage < 0.3);
    try std.testing.expect(estimate.confidence < 0.25);
}

test "native BGRA warper preserves an identity frame" {
    if (!warp.native_enabled) return error.SkipZigTest;

    const width = 8;
    const height = 6;
    var source: [width * height * 4]u8 = undefined;
    for (&source, 0..) |*channel, index| {
        channel.* = @intCast(index % 251);
    }
    var destination: [source.len]u8 = undefined;
    try warp.warpBgra(
        &source,
        width * 4,
        &destination,
        width * 4,
        width,
        height,
        warp.AffineMatrix.identity(),
    );
    try std.testing.expectEqualSlices(u8, &source, &destination);
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
    try std.testing.expect(video_decoder.info.framesPerSecond() != null);
    try std.testing.expect(video_decoder.info.duration_seconds != null);
    try std.testing.expect(video_decoder.info.duration_seconds.? > 0);

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

test "native decoder emits full-resolution BGRA render frames" {
    if (!decoder.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0) return error.SkipZigTest;

    var video_decoder = try decoder.Decoder.open(
        std.testing.allocator,
        build_options.test_video,
        .{ .output_format = .bgra8 },
    );
    defer video_decoder.deinit();

    const frame = try video_decoder.readFrame() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        video_decoder.info.source.width,
        frame.width,
    );
    try std.testing.expectEqual(
        video_decoder.info.source.height,
        frame.height,
    );
    try std.testing.expectEqual(decoder.PixelFormat.bgra8, frame.format);
    try std.testing.expectEqual(
        @as(usize, frame.width) * 4,
        frame.stride,
    );
    try std.testing.expectEqual(
        frame.stride * @as(usize, frame.height),
        frame.pixels.len,
    );
}

test "native analyzer emits one valid record per decoded frame" {
    if (!analyzer.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0 or
        build_options.test_video_frames == 0)
    {
        return error.SkipZigTest;
    }

    var video_analyzer = try analyzer.Analyzer.open(
        std.testing.allocator,
        build_options.test_video,
        .{ .decoder = .{ .max_analysis_dimension = 320 } },
    );
    defer video_analyzer.deinit();

    var validator = engine_types.SequenceValidator{};
    while (try video_analyzer.read()) |record| {
        try validator.push(record);
    }
    try validator.finish(build_options.test_video_frames);
}

test "native session builds a render plan for every frame" {
    if (!session.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0 or
        build_options.test_video_frames == 0)
    {
        return error.SkipZigTest;
    }

    var analysis = try session.Session.run(
        std.testing.allocator,
        build_options.test_video,
        .{
            .analyzer = .{
                .decoder = .{ .max_analysis_dimension = 320 },
            },
            .crop = .{ .max_zoom = 2 },
        },
    );
    defer analysis.deinit();

    try std.testing.expectEqual(
        @as(usize, @intCast(build_options.test_video_frames)),
        analysis.frameCount(),
    );
    try std.testing.expectEqual(analysis.records.len, analysis.corrections.len);
    try std.testing.expectEqual(analysis.records.len, analysis.crop_frames.len);
    for (analysis.crop_frames) |frame| {
        try std.testing.expect(frame.zoom >= frame.required_zoom);
        try std.testing.expect(frame.zoom <= 2);
    }
    _ = try analysis.renderMatrix(analysis.frameCount() - 1);
}

test "native renderer submits every stabilized BGRA frame" {
    if (!renderer.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0 or
        build_options.test_video_frames == 0)
    {
        return error.SkipZigTest;
    }

    var analysis = try session.Session.run(
        std.testing.allocator,
        build_options.test_video,
        .{
            .analyzer = .{
                .decoder = .{ .max_analysis_dimension = 320 },
            },
            .crop = .{ .max_zoom = 2 },
        },
    );
    defer analysis.deinit();
    var counter = RenderCounter{};
    try renderer.Renderer.run(
        std.testing.allocator,
        build_options.test_video,
        &analysis,
        .{
            .context = &counter,
            .on_frame = RenderCounter.onFrame,
        },
    );
    try std.testing.expectEqual(
        build_options.test_video_frames,
        counter.frame_count,
    );
    try std.testing.expect(counter.checksum > 0);
}

test "native encoder and muxer produce a playable MP4 container" {
    if (!encoder.native_enabled or !muxer.native_enabled) {
        return error.SkipZigTest;
    }
    if (build_options.test_video.len == 0) return error.SkipZigTest;

    const encoded_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.axia-encoded-test.mp4",
        .{build_options.test_video},
    );
    defer std.testing.allocator.free(encoded_path);
    defer deleteTestFile(encoded_path);
    const muxed_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.axia-muxed-test.mp4",
        .{build_options.test_video},
    );
    defer std.testing.allocator.free(muxed_path);
    defer deleteTestFile(muxed_path);
    deleteTestFile(encoded_path);
    deleteTestFile(muxed_path);

    const width = 64;
    const height = 48;
    const color_info = decoder.ColorInfo{
        .range = 1,
        .primaries = 1,
        .transfer = 1,
        .matrix = 1,
        .chroma_location = 1,
    };
    var pixels: [width * height * 4]u8 = undefined;
    @memset(&pixels, 96);
    var video_encoder = try encoder.Encoder.create(
        std.testing.allocator,
        encoded_path,
        .{ .width = width, .height = height },
        .{ .numerator = 1, .denominator = 30 },
        .{ .numerator = 30, .denominator = 1 },
        color_info,
        .{ .preset = "ultrafast" },
    );
    var encoder_open = true;
    defer if (encoder_open) video_encoder.deinit();
    for (0..3) |index| {
        try video_encoder.writeFrame(.{
            .timing = .{
                .index = @intCast(index),
                .pts = @intCast(index),
                .duration = 1,
                .time_base = .{ .numerator = 1, .denominator = 30 },
            },
            .pixels = &pixels,
            .width = width,
            .height = height,
            .stride = width * 4,
        });
    }
    try video_encoder.finish();
    video_encoder.deinit();
    encoder_open = false;

    var encoded_decoder = try decoder.Decoder.open(
        std.testing.allocator,
        encoded_path,
        .{ .output_format = .bgra8 },
    );
    defer encoded_decoder.deinit();
    try std.testing.expectEqual(
        color_info.range,
        encoded_decoder.info.color.range,
    );
    try std.testing.expectEqual(
        color_info.primaries,
        encoded_decoder.info.color.primaries,
    );
    try std.testing.expectEqual(
        color_info.transfer,
        encoded_decoder.info.color.transfer,
    );
    try std.testing.expectEqual(
        color_info.matrix,
        encoded_decoder.info.color.matrix,
    );
    const decoded_frame = (try encoded_decoder.readFrame()) orelse
        return error.TestUnexpectedResult;
    for (decoded_frame.pixels[0..3]) |channel| {
        try std.testing.expect(channel >= 90 and channel <= 102);
    }

    const mux_result = try muxer.Muxer.run(
        std.testing.allocator,
        encoded_path,
        build_options.test_video,
        muxed_path,
        .{},
    );
    if (build_options.test_video_audio_streams > 0) {
        try std.testing.expectEqual(
            build_options.test_video_audio_streams,
            mux_result.audio_streams,
        );
    }
    const stat = try std.fs.cwd().statFile(muxed_path);
    try std.testing.expect(stat.size > 0);
}

test "native exporter completes the full transactional pipeline" {
    if (!exporter.native_enabled) return error.SkipZigTest;
    if (build_options.test_video.len == 0 or
        build_options.test_video_frames == 0)
    {
        return error.SkipZigTest;
    }

    const output_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.axia-export-test.mp4",
        .{build_options.test_video},
    );
    defer std.testing.allocator.free(output_path);
    defer deleteTestFile(output_path);
    deleteTestFile(output_path);

    const result = try exporter.Exporter.run(
        std.testing.allocator,
        build_options.test_video,
        output_path,
        .{
            .session = .{
                .analyzer = .{
                    .decoder = .{ .max_analysis_dimension = 320 },
                },
                .crop = .{ .max_zoom = 2 },
            },
            .encoder = .{ .crf = 16, .preset = "slow" },
        },
    );
    try std.testing.expectEqual(build_options.test_video_frames, result.frames);
    if (build_options.test_video_audio_streams > 0) {
        try std.testing.expectEqual(
            build_options.test_video_audio_streams,
            result.audio_streams,
        );
    }
    const stat = try std.fs.cwd().statFile(output_path);
    try std.testing.expect(stat.size > 0);
}

const RenderCounter = struct {
    frame_count: u64 = 0,
    checksum: u64 = 0,

    fn onFrame(raw_context: ?*anyopaque, frame: renderer.Frame) bool {
        const self: *RenderCounter = @ptrCast(@alignCast(raw_context.?));
        self.frame_count += 1;
        const pixel_count = frame.pixels.len / 4;
        const step = @max(1, pixel_count / 64);
        var pixel: usize = 0;
        while (pixel < pixel_count) : (pixel += step) {
            const offset = pixel * 4;
            self.checksum +%= frame.pixels[offset];
            self.checksum +%= frame.pixels[offset + 1];
            self.checksum +%= frame.pixels[offset + 2];
        }
        return true;
    }
};

fn deleteTestFile(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}
