const std = @import("std");

/// Maps the product's smoothness control to libvidstab's frame radius.
/// Kept inside the legacy boundary so the native engine is free to use
/// timestamp-aware trajectory windows.
pub fn smoothingRadius(smoothness: f32, fps: f32) usize {
    const normalized = std.math.clamp(smoothness, 0.0, 100.0) / 100.0;
    const frames = normalized * normalized * fps * 2.0;
    return @intFromFloat(@round(frames));
}
