const std = @import("std");

pub const TrajectoryError = error{
    InvalidScale,
};

/// Motion measured from frame N-1 to frame N.
pub const RelativeMotion = struct {
    dx: f64 = 0,
    dy: f64 = 0,
    dtheta: f64 = 0,
    scale: f64 = 1,
    confidence: f32 = 1,
    scene_cut: bool = false,
};

/// Integrated camera pose for one decoded frame.
pub const Pose = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
    log_scale: f64 = 0,
    confidence: f32 = 1,
    segment: u32 = 0,
};

pub const Correction = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
    scale: f64 = 1,
};

/// Produces one pose per video frame, including the identity pose for frame 0.
/// A scene cut starts a new coordinate system so smoothing never pulls motion
/// across unrelated shots.
pub fn integrate(
    allocator: std.mem.Allocator,
    motions: []const RelativeMotion,
) (TrajectoryError || std.mem.Allocator.Error)![]Pose {
    const poses = try allocator.alloc(Pose, motions.len + 1);
    poses[0] = .{};

    var current = Pose{};
    for (motions, 0..) |motion, index| {
        if (motion.scene_cut) {
            current = .{ .segment = current.segment + 1 };
        } else {
            if (!std.math.isFinite(motion.scale) or motion.scale <= 0) return error.InvalidScale;
            current.x += motion.dx;
            current.y += motion.dy;
            current.angle += motion.dtheta;
            current.log_scale += @log(motion.scale);
            current.confidence = std.math.clamp(motion.confidence, 0.0, 1.0);
        }
        poses[index + 1] = current;
    }
    return poses;
}

/// Confidence-weighted Gaussian smoothing performed independently per shot.
/// Low-confidence poses contribute less, while a small floor prevents a window
/// containing only weak measurements from becoming undefined.
pub fn smooth(
    allocator: std.mem.Allocator,
    poses: []const Pose,
    radius: usize,
) std.mem.Allocator.Error![]Pose {
    const output = try allocator.alloc(Pose, poses.len);
    if (poses.len == 0) return output;
    if (radius == 0) {
        @memcpy(output, poses);
        return output;
    }

    const sigma = @max(1.0, @as(f64, @floatFromInt(radius)) / 2.0);
    for (poses, 0..) |pose, index| {
        const start = index -| radius;
        const end = @min(poses.len, index +| radius +| 1);
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        var sum_angle: f64 = 0;
        var sum_log_scale: f64 = 0;
        var sum_weight: f64 = 0;

        for (poses[start..end], start..) |sample, sample_index| {
            if (sample.segment != pose.segment) continue;
            const distance: f64 = @floatFromInt(if (sample_index > index)
                sample_index - index
            else
                index - sample_index);
            const temporal_weight = @exp(-0.5 * distance * distance / (sigma * sigma));
            const confidence_weight = @max(0.001, @as(f64, sample.confidence));
            const weight = temporal_weight * confidence_weight;
            sum_x += sample.x * weight;
            sum_y += sample.y * weight;
            sum_angle += sample.angle * weight;
            sum_log_scale += sample.log_scale * weight;
            sum_weight += weight;
        }

        output[index] = .{
            .x = sum_x / sum_weight,
            .y = sum_y / sum_weight,
            .angle = sum_angle / sum_weight,
            .log_scale = sum_log_scale / sum_weight,
            .confidence = pose.confidence,
            .segment = pose.segment,
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
        correction.* = .{
            .x = smooth_pose.x - raw_pose.x,
            .y = smooth_pose.y - raw_pose.y,
            .angle = smooth_pose.angle - raw_pose.angle,
            .scale = @exp(smooth_pose.log_scale - raw_pose.log_scale),
        };
    }
    return output;
}
