const std = @import("std");
const build_options = @import("build_options");

pub const types = @import("types.zig");
pub const decoder = @import("decoder.zig");
pub const features = @import("features.zig");
pub const motion = @import("motion.zig");
pub const analyzer = @import("analyzer.zig");
pub const trajectory = @import("trajectory.zig");
pub const warp = @import("warp.zig");
pub const crop = @import("crop.zig");
pub const session = @import("session.zig");
pub const renderer = @import("renderer.zig");
pub const encoder = @import("encoder.zig");
pub const muxer = @import("muxer.zig");
pub const exporter = @import("exporter.zig");

pub const native_dependencies_enabled =
    build_options.native_ffmpeg and build_options.native_opencv;

pub const AvailabilityError = error{
    NativeDependenciesDisabled,
};

/// The product has a single engine. Focused dependency switches remain
/// available only so FFmpeg and OpenCV adapters can be tested independently.
pub fn ensureReady() AvailabilityError!void {
    if (!native_dependencies_enabled) return error.NativeDependenciesDisabled;
}

test "complete engine requires both native dependencies" {
    if (native_dependencies_enabled) {
        try ensureReady();
    } else {
        try std.testing.expectError(
            error.NativeDependenciesDisabled,
            ensureReady(),
        );
    }
}
