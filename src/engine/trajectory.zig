const std = @import("std");
const types = @import("types.zig");

pub const TrajectoryError = error{
    InvalidSmoothingWindow,
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
    const poses = try allocator.alloc(Pose, records.len);
    errdefer allocator.free(poses);
    if (records.len == 0) return poses;

    var validator = types.SequenceValidator{};
    var current = types.SimilarityTransform.identity();
    for (records, 0..) |record, index| {
        try validator.push(record);
        if (index == 0 or record.flags.scene_cut) {
            current = types.SimilarityTransform.identity();
        } else {
            // A weak pairwise estimate must not poison every absolute pose
            // that follows it. Missing motion can be handled as a local loss
            // of stabilization; integrating an outlier creates a permanent
            // jump in the camera path.
            const measured_motion = if (record.flags.low_confidence or
                record.flags.fallback)
                types.SimilarityTransform.identity()
            else
                record.global_motion_from_previous;
            current = compose(
                measured_motion,
                current,
            );
        }
        poses[index] = poseFromTransform(
            current,
            record.confidence,
            record.scene_id,
            try record.timing.presentationSeconds(),
        );
    }
    try validator.finish(@intCast(records.len));
    return poses;
}

/// Timestamp-aware smoothing for the native pipeline. `radius_seconds` has the
/// same meaning for CFR and VFR media because distances come from frame PTS.
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
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        var sum_angle_x: f64 = 0;
        var sum_angle_y: f64 = 0;
        var sum_log_scale: f64 = 0;
        var sum_weight: f64 = 0;

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
            sum_x += sample.x * weight;
            sum_y += sample.y * weight;
            sum_angle_x += @cos(sample.angle) * weight;
            sum_angle_y += @sin(sample.angle) * weight;
            sum_log_scale += sample.log_scale * weight;
            sum_weight += weight;
        }

        output[index] = .{
            .x = sum_x / sum_weight,
            .y = sum_y / sum_weight,
            .angle = std.math.atan2(sum_angle_y, sum_angle_x),
            .log_scale = sum_log_scale / sum_weight,
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
