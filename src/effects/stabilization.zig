const std = @import("std");

pub const Mode = enum {
    motion,
    distortion,
};

pub const Error = error{
    InvalidSmoothness,
    InvalidCrop,
};

/// Serializable parameters for the temporal stabilization effect.
/// Analysis results live in a separate cache and are keyed by these values.
pub const Stabilization = struct {
    enabled: bool = true,
    smoothness_percent: f32 = 72,
    extra_crop_percent: f32 = 12,
    dynamic_crop: bool = true,
    mode: Mode = .motion,

    pub fn validate(self: Stabilization) Error!void {
        if (!std.math.isFinite(self.smoothness_percent) or
            self.smoothness_percent < 0 or self.smoothness_percent > 100)
        {
            return error.InvalidSmoothness;
        }
        if (!std.math.isFinite(self.extra_crop_percent) or
            self.extra_crop_percent < 0 or self.extra_crop_percent > 30)
        {
            return error.InvalidCrop;
        }
    }
};

test "stabilization parameters reject values outside the editor range" {
    try (Stabilization{}).validate();
    try std.testing.expectError(
        error.InvalidSmoothness,
        (Stabilization{ .smoothness_percent = 101 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidCrop,
        (Stabilization{ .extra_crop_percent = -1 }).validate(),
    );
}
