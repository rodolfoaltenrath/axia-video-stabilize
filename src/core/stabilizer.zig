const std = @import("std");
const tracker = @import("tracker.zig");

pub const Transform = struct { x: f64 = 0, y: f64 = 0, angle: f64 = 0 };

pub fn accumulate(allocator: std.mem.Allocator, motions: []const tracker.Motion) ![]Transform {
    const trajectory = try allocator.alloc(Transform, motions.len);
    var current = Transform{};
    for (motions, 0..) |motion, index| {
        current.x += motion.dx;
        current.y += motion.dy;
        current.angle += motion.dtheta;
        trajectory[index] = current;
    }
    return trajectory;
}

/// Centered moving-average smoother. This is deliberately scalar and clear;
/// profiling will determine whether the production Gaussian/Kalman path needs
/// SIMD. Edge samples use the available neighborhood instead of padding.
pub fn smooth(allocator: std.mem.Allocator, trajectory: []const Transform, radius: usize) ![]Transform {
    const output = try allocator.alloc(Transform, trajectory.len);
    if (trajectory.len == 0) return output;

    for (trajectory, 0..) |_, index| {
        const start = index -| radius;
        const end = @min(trajectory.len, index +| radius +| 1);
        var sum = Transform{};
        for (trajectory[start..end]) |sample| {
            sum.x += sample.x;
            sum.y += sample.y;
            sum.angle += sample.angle;
        }
        const count: f64 = @floatFromInt(end - start);
        output[index] = .{ .x = sum.x / count, .y = sum.y / count, .angle = sum.angle / count };
    }
    return output;
}

pub fn correction(raw: Transform, smoothed: Transform) Transform {
    return .{
        .x = smoothed.x - raw.x,
        .y = smoothed.y - raw.y,
        .angle = smoothed.angle - raw.angle,
    };
}

pub fn radiusFromSmoothness(smoothness: f32, fps: f32) usize {
    const normalized = std.math.clamp(smoothness, 0.0, 100.0) / 100.0;
    const frames = normalized * normalized * fps * 2.0;
    return @intFromFloat(@round(frames));
}

// Warping hook: create a 2x3 affine matrix from correction(), apply warpAffine
// and derive the smallest safe scale/crop over a temporal window.
