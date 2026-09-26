const std = @import("std");

pub const Error = error{InvalidTransform};

pub const Transform = struct {
    enabled: bool = true,
    translation_x: f64 = 0,
    translation_y: f64 = 0,
    rotation_radians: f64 = 0,
    scale: f64 = 1,

    pub fn validate(self: Transform) Error!void {
        if (!std.math.isFinite(self.translation_x) or
            !std.math.isFinite(self.translation_y) or
            !std.math.isFinite(self.rotation_radians) or
            !std.math.isFinite(self.scale) or self.scale <= 0)
        {
            return error.InvalidTransform;
        }
    }
};
