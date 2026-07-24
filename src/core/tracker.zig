const std = @import("std");
const video = @import("video.zig");

pub const Point = struct { x: f32, y: f32 };
pub const Track = struct { previous: Point, current: Point, error_score: f32 };

pub const Motion = struct {
    dx: f64 = 0,
    dy: f64 = 0,
    dtheta: f64 = 0,
    inlier_ratio: f32 = 0,
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{ .allocator = allocator };
    }

    pub fn estimate(self: *Tracker, previous: *const video.Frame, current: *const video.Frame) !Motion {
        _ = self;
        _ = previous;
        _ = current;

        // OpenCV/native hook point:
        // 1. goodFeaturesToTrack on the previous gray8 frame.
        // 2. calcOpticalFlowPyrLK to build Track pairs.
        // 3. estimateAffinePartial2D(..., RANSAC) to reject moving objects.
        // 4. Extract dx, dy and atan2(m10, m00) as dtheta.
        return .{};
    }
};
