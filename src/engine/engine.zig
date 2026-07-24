const std = @import("std");
const build_options = @import("build_options");

pub const types = @import("types.zig");
pub const decoder = @import("decoder.zig");

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
    NativeEngineNotImplemented,
};

/// Fails explicitly while the native implementation is being built instead of
/// silently routing a `-Dengine=native` build through libvidstab.
pub fn ensureSelectedBackendIsReady() AvailabilityError!void {
    if (selected_backend == .legacy) return;
    if (!native_dependencies_enabled) return error.NativeDependenciesDisabled;
    return error.NativeEngineNotImplemented;
}

test "engine module has a valid compile-time backend" {
    try std.testing.expect(selected_backend == .legacy or selected_backend == .native);
}
