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

pub const Backend = enum {
    legacy,
    native,
};

pub const selected_backend: Backend = switch (build_options.engine_backend) {
    .legacy => .legacy,
    .native => .native,
};
pub const native_dependencies_enabled =
    build_options.native_ffmpeg and build_options.native_opencv;

pub const AvailabilityError = error{
    NativeDependenciesDisabled,
    NativeExportNotImplemented,
};

/// Native analysis and frame rendering are available, but product selection
/// remains blocked until encoding and audio muxing complete an export.
pub fn ensureSelectedBackendIsReady() AvailabilityError!void {
    if (selected_backend == .legacy) return;
    if (!native_dependencies_enabled) return error.NativeDependenciesDisabled;
    return error.NativeExportNotImplemented;
}

test "engine module has a valid compile-time backend" {
    try std.testing.expect(selected_backend == .legacy or selected_backend == .native);
}
