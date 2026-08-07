const std = @import("std");
const types = @import("types.zig");

pub const TrajectoryError = error{
    InvalidIntegrationOptions,
    InvalidTrajectoryTimestamp,
    InvalidSmoothingWindow,
    TrajectorySegmentOverflow,
};

pub const IntegrationOptions = struct {
    /// Zero disables reconstruction. Gaps need reliable samples on both sides.
    maximum_interpolated_gap_frames: u8 = 3,
    /// Rejects one-frame motion impulses only when both neighbours agree.
    reject_isolated_motion_spikes: bool = true,
    /// Starts neutral smoothing/crop segments around gaps that remain unknown.
    rebase_unresolved_gaps: bool = true,
    /// Maximum change in pairwise translation velocity, in analysis pixels/s².
    maximum_translation_acceleration: f64 = 20_000,
    /// Maximum change in pairwise angular velocity, in radians/s².
    maximum_rotation_acceleration: f64 = 100,
    /// Maximum change in logarithmic scale velocity, in log(scale)/s².
    maximum_log_scale_acceleration: f64 = 50,
};

/// Integrated camera pose for one decoded frame.
pub const Pose = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
    log_scale: f64 = 0,
    confidence: f32 = 1,
    segment: u32 = 0,
    timestamp_seconds: f64 = 0,
};

pub const Correction = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
    scale: f64 = 1,
};

/// Integrates the analyzer's canonical per-frame records into camera poses.
/// Similarity transforms are composed geometrically instead of adding their
/// translations, which remains correct when rotation or scale is present.
pub fn integrateAnalysis(
    allocator: std.mem.Allocator,
    records: []const types.AnalysisRecord,
) (TrajectoryError || types.ValidationError ||
    std.mem.Allocator.Error)![]Pose {
    return integrateAnalysisWithOptions(allocator, records, .{});
}

pub fn integrateAnalysisWithOptions(
    allocator: std.mem.Allocator,
    records: []const types.AnalysisRecord,
    options: IntegrationOptions,
) (TrajectoryError || types.ValidationError ||
    std.mem.Allocator.Error)![]Pose {
    try validateIntegrationOptions(options);
    const poses = try allocator.alloc(Pose, records.len);
    errdefer allocator.free(poses);
    if (records.len == 0) return poses;

    const samples = try allocator.alloc(PairwiseSample, records.len);
    defer allocator.free(samples);
    var validator = types.SequenceValidator{};
    for (records, 0..) |record, index| {
        try validator.push(record);
        const timestamp = try record.timing.presentationSeconds();
        if (index > 0 and timestamp <= samples[index - 1].timestamp_seconds) {
            return error.InvalidTrajectoryTimestamp;
        }
        const reliable = index > 0 and
            !record.flags.scene_cut and
            !record.flags.low_confidence and
            !record.flags.fallback;
        samples[index] = .{
            .transform = if (reliable)
                record.global_motion_from_previous
            else
                types.SimilarityTransform.identity(),
            .timestamp_seconds = timestamp,
            .duration_seconds = if (index == 0)
                0
            else
                timestamp - samples[index - 1].timestamp_seconds,
            .scene_id = record.scene_id,
            .scene_cut = record.flags.scene_cut,
            .reliable = reliable,
        };
    }
    try validator.finish(@intCast(records.len));
    if (options.reject_isolated_motion_spikes) {
        rejectIsolatedMotionSpikes(samples, options);
    }
    interpolateShortGaps(samples, options);

    var current = types.SimilarityTransform.identity();
    var trajectory_segment: u32 = 0;
    var inside_unresolved_gap = false;
    for (records, samples, poses, 0..) |record, sample, *pose, index| {
        if (index == 0) {
            current = types.SimilarityTransform.identity();
        } else if (record.flags.scene_cut) {
            current = types.SimilarityTransform.identity();
            inside_unresolved_gap = false;
            trajectory_segment = std.math.add(
                u32,
                trajectory_segment,
                1,
            ) catch return error.TrajectorySegmentOverflow;
        } else if (options.rebase_unresolved_gaps and !sample.reliable) {
            if (!inside_unresolved_gap) {
                current = types.SimilarityTransform.identity();
                inside_unresolved_gap = true;
                trajectory_segment = std.math.add(
                    u32,
                    trajectory_segment,
                    1,
                ) catch return error.TrajectorySegmentOverflow;
            }
        } else {
            if (options.rebase_unresolved_gaps and inside_unresolved_gap) {
                current = types.SimilarityTransform.identity();
                inside_unresolved_gap = false;
                trajectory_segment = std.math.add(
                    u32,
                    trajectory_segment,
                    1,
                ) catch return error.TrajectorySegmentOverflow;
            }
            current = compose(
                sample.transform,
                current,
            );
        }
        pose.* = poseFromTransform(
            current,
            record.confidence,
            trajectory_segment,
            sample.timestamp_seconds,
        );
    }
    return poses;
}

const PairwiseSample = struct {
    transform: types.SimilarityTransform,
    timestamp_seconds: f64,
    duration_seconds: f64,
    scene_id: u32,
    scene_cut: bool,
    reliable: bool,
};

const MotionRate = struct {
    x: f64,
    y: f64,
    angle: f64,
    log_scale: f64,
};

/// Converts a confident but temporally implausible one-frame impulse into a
/// gap. `interpolateShortGaps` can then rebuild it from the agreeing samples
/// on both sides. Real starts or stops are retained because their neighbours
/// do not agree with each other.
fn rejectIsolatedMotionSpikes(
    samples: []PairwiseSample,
    options: IntegrationOptions,
) void {
    if (samples.len < 4) return;

    var index: usize = 2;
    while (index + 1 < samples.len) : (index += 1) {
        const left = samples[index - 1];
        const current = samples[index];
        const right = samples[index + 1];
        if (!left.reliable or !current.reliable or !right.reliable or
            left.scene_cut or current.scene_cut or right.scene_cut or
            left.scene_id != current.scene_id or
            current.scene_id != right.scene_id)
        {
            continue;
        }

        const left_rate = motionRate(left);
        const current_rate = motionRate(current);
        const right_rate = motionRate(right);
        const neighbours_agree = ratesAreCompatible(
            left_rate,
            right_rate,
            right.timestamp_seconds - left.timestamp_seconds,
            options,
        );
        const left_agrees_with_current = ratesAreCompatible(
            left_rate,
            current_rate,
            current.timestamp_seconds - left.timestamp_seconds,
            options,
        );
        const current_agrees_with_right = ratesAreCompatible(
            current_rate,
            right_rate,
            right.timestamp_seconds - current.timestamp_seconds,
            options,
        );
        if (!neighbours_agree or
            left_agrees_with_current or
            current_agrees_with_right)
        {
            continue;
        }

        samples[index].transform = types.SimilarityTransform.identity();
        samples[index].reliable = false;
    }
}

fn interpolateShortGaps(
    samples: []PairwiseSample,
    options: IntegrationOptions,
) void {
    if (options.maximum_interpolated_gap_frames == 0 or samples.len < 3) {
        return;
    }

    var index: usize = 1;
    while (index < samples.len) {
        if (samples[index].scene_cut or samples[index].reliable) {
            index += 1;
            continue;
        }

        const gap_start = index;
        const scene_id = samples[index].scene_id;
        while (index < samples.len and
            !samples[index].scene_cut and
            samples[index].scene_id == scene_id and
            !samples[index].reliable)
        {
            index += 1;
        }
        const gap_end = index;
        const gap_length = gap_end - gap_start;
        if (gap_length > options.maximum_interpolated_gap_frames or
            gap_start == 0 or gap_end >= samples.len)
        {
            continue;
        }

        const left = samples[gap_start - 1];
        const right = samples[gap_end];
        if (!left.reliable or !right.reliable or
            left.scene_id != scene_id or right.scene_id != scene_id)
        {
            continue;
        }
        const left_rate = motionRate(left);
        const right_rate = motionRate(right);
        const boundary_seconds = right.timestamp_seconds -
            left.timestamp_seconds;
        if (!ratesAreCompatible(
            left_rate,
            right_rate,
            boundary_seconds,
            options,
        )) {
            continue;
        }

        for (samples[gap_start..gap_end]) |*sample| {
            const amount = (sample.timestamp_seconds -
                left.timestamp_seconds) / boundary_seconds;
            sample.transform = transformFromRate(
                interpolateRate(left_rate, right_rate, amount),
                sample.duration_seconds,
            );
            sample.reliable = true;
        }
    }
}

fn motionRate(sample: PairwiseSample) MotionRate {
    return .{
        .x = sample.transform.x / sample.duration_seconds,
        .y = sample.transform.y / sample.duration_seconds,
        .angle = sample.transform.angle / sample.duration_seconds,
        .log_scale = @log(sample.transform.scale) / sample.duration_seconds,
    };
}

fn interpolateRate(left: MotionRate, right: MotionRate, amount: f64) MotionRate {
    return .{
        .x = left.x + (right.x - left.x) * amount,
        .y = left.y + (right.y - left.y) * amount,
        .angle = left.angle + (right.angle - left.angle) * amount,
        .log_scale = left.log_scale +
            (right.log_scale - left.log_scale) * amount,
    };
}

fn transformFromRate(rate: MotionRate, duration_seconds: f64) types.SimilarityTransform {
    return .{
        .x = rate.x * duration_seconds,
        .y = rate.y * duration_seconds,
        .angle = rate.angle * duration_seconds,
        .scale = @exp(rate.log_scale * duration_seconds),
    };
}

fn ratesAreCompatible(
    left: MotionRate,
    right: MotionRate,
    elapsed_seconds: f64,
    options: IntegrationOptions,
) bool {
    if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds <= 0) {
        return false;
    }
    const acceleration_x = (right.x - left.x) / elapsed_seconds;
    const acceleration_y = (right.y - left.y) / elapsed_seconds;
    const translation_acceleration = @sqrt(
        acceleration_x * acceleration_x +
            acceleration_y * acceleration_y,
    );
    const rotation_acceleration = @abs(
        (right.angle - left.angle) / elapsed_seconds,
    );
    const scale_acceleration = @abs(
        (right.log_scale - left.log_scale) / elapsed_seconds,
    );
    return translation_acceleration <=
        options.maximum_translation_acceleration and
        rotation_acceleration <= options.maximum_rotation_acceleration and
        scale_acceleration <= options.maximum_log_scale_acceleration;
}

fn validateIntegrationOptions(options: IntegrationOptions) TrajectoryError!void {
    if (!std.math.isFinite(options.maximum_translation_acceleration) or
        options.maximum_translation_acceleration <= 0 or
        !std.math.isFinite(options.maximum_rotation_acceleration) or
        options.maximum_rotation_acceleration <= 0 or
        !std.math.isFinite(options.maximum_log_scale_acceleration) or
        options.maximum_log_scale_acceleration <= 0)
    {
        return error.InvalidIntegrationOptions;
    }
}

const LocalLinearFit = struct {
    weight: f64 = 0,
    weighted_time: f64 = 0,
    weighted_time_squared: f64 = 0,
    weighted_x: f64 = 0,
    weighted_time_x: f64 = 0,
    weighted_y: f64 = 0,
    weighted_time_y: f64 = 0,
    weighted_angle: f64 = 0,
    weighted_time_angle: f64 = 0,
    weighted_log_scale: f64 = 0,
    weighted_time_log_scale: f64 = 0,

    fn add(self: *LocalLinearFit, time: f64, pose: Pose, sample_weight: f64) void {
        self.weight += sample_weight;
        self.weighted_time += sample_weight * time;
        self.weighted_time_squared += sample_weight * time * time;
        self.weighted_x += sample_weight * pose.x;
        self.weighted_time_x += sample_weight * time * pose.x;
        self.weighted_y += sample_weight * pose.y;
        self.weighted_time_y += sample_weight * time * pose.y;
        self.weighted_angle += sample_weight * pose.angle;
        self.weighted_time_angle += sample_weight * time * pose.angle;
        self.weighted_log_scale += sample_weight * pose.log_scale;
        self.weighted_time_log_scale += sample_weight * time * pose.log_scale;
    }

    fn estimateAtCenter(
        self: LocalLinearFit,
        weighted_value: f64,
        weighted_time_value: f64,
    ) f64 {
        const determinant = self.weight * self.weighted_time_squared -
            self.weighted_time * self.weighted_time;
        const determinant_scale = @max(
            1.0,
            @abs(self.weight * self.weighted_time_squared) +
                @abs(self.weighted_time * self.weighted_time),
        );
        if (@abs(determinant) <=
            64.0 * std.math.floatEps(f64) * determinant_scale)
        {
            return weighted_value / self.weight;
        }
        return (self.weighted_time_squared * weighted_value -
            self.weighted_time * weighted_time_value) / determinant;
    }
};

/// Timestamp-aware local-linear Gaussian smoothing for the native pipeline.
/// The fitted slope prevents a steady pan, rotation or zoom from bending near
/// scene boundaries where a simple weighted average has samples on one side.
/// `radius_seconds` has the same meaning for CFR and VFR media because all
/// distances come from frame PTS.
pub fn smoothTimed(
    allocator: std.mem.Allocator,
    poses: []const Pose,
    radius_seconds: f64,
) (TrajectoryError || std.mem.Allocator.Error)![]Pose {
    if (!std.math.isFinite(radius_seconds) or radius_seconds < 0) {
        return error.InvalidSmoothingWindow;
    }
    const output = try allocator.alloc(Pose, poses.len);
    if (poses.len == 0) return output;
    if (radius_seconds == 0) {
        @memcpy(output, poses);
        return output;
    }

    const sigma = @max(0.001, radius_seconds / 2.0);
    for (poses, 0..) |pose, index| {
        var fit = LocalLinearFit{};

        var sample_index = index;
        while (sample_index > 0 and
            poses[sample_index - 1].segment == pose.segment and
            pose.timestamp_seconds -
            poses[sample_index - 1].timestamp_seconds <= radius_seconds)
        {
            sample_index -= 1;
        }
        while (sample_index < poses.len) : (sample_index += 1) {
            const sample = poses[sample_index];
            if (sample.segment != pose.segment) break;
            const distance = @abs(
                sample.timestamp_seconds - pose.timestamp_seconds,
            );
            if (distance > radius_seconds) {
                if (sample_index > index) break;
                continue;
            }
            const temporal_weight = @exp(
                -0.5 * distance * distance / (sigma * sigma),
            );
            const confidence_weight = @max(
                0.001,
                @as(f64, @floatCast(sample.confidence)),
            );
            const weight = temporal_weight * confidence_weight;
            fit.add(
                sample.timestamp_seconds - pose.timestamp_seconds,
                sample,
                weight,
            );
        }

        output[index] = .{
            .x = fit.estimateAtCenter(fit.weighted_x, fit.weighted_time_x),
            .y = fit.estimateAtCenter(fit.weighted_y, fit.weighted_time_y),
            .angle = fit.estimateAtCenter(
                fit.weighted_angle,
                fit.weighted_time_angle,
            ),
            .log_scale = fit.estimateAtCenter(
                fit.weighted_log_scale,
                fit.weighted_time_log_scale,
            ),
            .confidence = pose.confidence,
            .segment = pose.segment,
            .timestamp_seconds = pose.timestamp_seconds,
        };
    }
    return output;
}

pub fn buildCorrections(
    allocator: std.mem.Allocator,
    raw: []const Pose,
    smoothed: []const Pose,
) (error{LengthMismatch} || std.mem.Allocator.Error)![]Correction {
    if (raw.len != smoothed.len) return error.LengthMismatch;
    const output = try allocator.alloc(Correction, raw.len);
    for (raw, smoothed, output) |raw_pose, smooth_pose, *correction| {
        const raw_transform = transformFromPose(raw_pose);
        const smooth_transform = transformFromPose(smooth_pose);
        const value = compose(smooth_transform, inverse(raw_transform));
        correction.* = .{
            .x = value.x,
            .y = value.y,
            .angle = value.angle,
            .scale = value.scale,
        };
    }
    return output;
}

fn compose(
    after: types.SimilarityTransform,
    before: types.SimilarityTransform,
) types.SimilarityTransform {
    const cosine = @cos(after.angle) * after.scale;
    const sine = @sin(after.angle) * after.scale;
    return .{
        .x = cosine * before.x - sine * before.y + after.x,
        .y = sine * before.x + cosine * before.y + after.y,
        .angle = after.angle + before.angle,
        .scale = after.scale * before.scale,
    };
}

fn inverse(
    transform: types.SimilarityTransform,
) types.SimilarityTransform {
    const inverse_scale = 1.0 / transform.scale;
    const inverse_angle = -transform.angle;
    const cosine = @cos(inverse_angle) * inverse_scale;
    const sine = @sin(inverse_angle) * inverse_scale;
    return .{
        .x = -(cosine * transform.x - sine * transform.y),
        .y = -(sine * transform.x + cosine * transform.y),
        .angle = inverse_angle,
        .scale = inverse_scale,
    };
}

fn poseFromTransform(
    transform: types.SimilarityTransform,
    confidence: f32,
    segment: u32,
    timestamp_seconds: f64,
) Pose {
    return .{
        .x = transform.x,
        .y = transform.y,
        .angle = transform.angle,
        .log_scale = @log(transform.scale),
        .confidence = confidence,
        .segment = segment,
        .timestamp_seconds = timestamp_seconds,
    };
}

fn transformFromPose(pose: Pose) types.SimilarityTransform {
    return .{
        .x = pose.x,
        .y = pose.y,
        .angle = pose.angle,
        .scale = @exp(pose.log_scale),
    };
}

fn testMotionRecord(index: u64, translation_x: f64) types.AnalysisRecord {
    return .{
        .timing = .{
            .index = index,
            .pts = @intCast(index),
            .time_base = .{ .numerator = 1, .denominator = 30 },
        },
        .global_motion_from_previous = .{ .x = translation_x },
        .confidence = 1,
    };
}

test "isolated confident motion spike is reconstructed from neighbours" {
    const records = [_]types.AnalysisRecord{
        types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        }, 0),
        testMotionRecord(1, 1),
        testMotionRecord(2, 30),
        testMotionRecord(3, 1),
    };
    const poses = try integrateAnalysis(std.testing.allocator, &records);
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 1), poses[1].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3), poses[3].x, 0.000001);
}

test "sustained fast motion is not treated as an isolated spike" {
    const records = [_]types.AnalysisRecord{
        types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        }, 0),
        testMotionRecord(1, 1),
        testMotionRecord(2, 30),
        testMotionRecord(3, 30),
    };
    const poses = try integrateAnalysis(std.testing.allocator, &records);
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 31), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 61), poses[3].x, 0.000001);
}

test "isolated motion spike rejection can be disabled" {
    const records = [_]types.AnalysisRecord{
        types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        }, 0),
        testMotionRecord(1, 1),
        testMotionRecord(2, 30),
        testMotionRecord(3, 1),
    };
    const poses = try integrateAnalysisWithOptions(
        std.testing.allocator,
        &records,
        .{ .reject_isolated_motion_spikes = false },
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 32), poses[3].x, 0.000001);
}

test "rebasing around unresolved gaps can be disabled" {
    var missing = testMotionRecord(2, 100);
    missing.confidence = 0;
    missing.flags = .{ .low_confidence = true, .fallback = true };
    const records = [_]types.AnalysisRecord{
        types.AnalysisRecord.reference(.{
            .index = 0,
            .pts = 0,
            .time_base = .{ .numerator = 1, .denominator = 30 },
        }, 0),
        testMotionRecord(1, 1),
        missing,
        testMotionRecord(3, 1),
    };
    const poses = try integrateAnalysisWithOptions(
        std.testing.allocator,
        &records,
        .{
            .maximum_interpolated_gap_frames = 0,
            .rebase_unresolved_gaps = false,
        },
    );
    defer std.testing.allocator.free(poses);

    try std.testing.expectApproxEqAbs(@as(f64, 1), poses[2].x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[3].x, 0.000001);
    try std.testing.expectEqual(@as(u32, 0), poses[2].segment);
    try std.testing.expectEqual(@as(u32, 0), poses[3].segment);
}
