const std = @import("std");
const effect_mod = @import("../effects/stabilization.zig");
const crop = @import("crop.zig");
const session = @import("session.zig");

pub const Effect = effect_mod.Stabilization;

pub const Error = error{
    EffectDisabled,
    DistortionModeNotImplemented,
} || effect_mod.Error;

/// Converts the editor-facing, serializable effect into engine options. This
/// is the only place where UI percentages know about stabilization internals.
pub fn sessionOptions(effect: Effect) Error!session.Options {
    try effect.validate();
    if (!effect.enabled) return error.EffectDisabled;
    if (effect.mode == .distortion) {
        return error.DistortionModeNotImplemented;
    }
    const normalized_smoothness =
        @as(f64, effect.smoothness_percent) / 100.0;
    return .{
        .smoothing_radius_seconds = normalized_smoothness * normalized_smoothness * 2.0,
        .crop = .{
            .mode = if (effect.dynamic_crop) .dynamic else .static,
            .extra_crop_fraction = @as(f64, effect.extra_crop_percent) / 100.0,
        },
    };
}

test "editor stabilization effect maps to engine session options" {
    const options = try sessionOptions(.{
        .smoothness_percent = 50,
        .extra_crop_percent = 10,
        .dynamic_crop = false,
    });
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        options.smoothing_radius_seconds,
        0.000001,
    );
    try std.testing.expectEqual(crop.Mode.static, options.crop.mode);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        options.crop.extra_crop_fraction,
        0.000001,
    );
}
