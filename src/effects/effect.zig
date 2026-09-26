const stabilization_mod = @import("stabilization.zig");
const transform_mod = @import("transform.zig");

pub const Kind = enum {
    transform,
    stabilization,
};

pub const PreparationKind = enum {
    stabilization_analysis,
};

pub const Error = stabilization_mod.Error || transform_mod.Error;

/// Typed internal effect contract. A tagged union keeps project files and
/// render dispatch exhaustive while the effect API is still evolving.
pub const Effect = union(Kind) {
    transform: transform_mod.Transform,
    stabilization: stabilization_mod.Stabilization,

    pub fn kind(self: Effect) Kind {
        return std.meta.activeTag(self);
    }

    pub fn enabled(self: Effect) bool {
        return switch (self) {
            inline else => |value| value.enabled,
        };
    }

    pub fn requiresPreparation(self: Effect) bool {
        return self.preparationKind() != null;
    }

    pub fn preparationKind(self: Effect) ?PreparationKind {
        if (!self.enabled()) return null;
        return switch (self) {
            .stabilization => .stabilization_analysis,
            .transform => null,
        };
    }

    pub fn validate(self: Effect) Error!void {
        return switch (self) {
            inline else => |value| value.validate(),
        };
    }
};

const std = @import("std");

test "only enabled temporal effects require preparation" {
    const transform = Effect{ .transform = .{} };
    const stabilization = Effect{ .stabilization = .{} };
    const disabled = Effect{
        .stabilization = .{ .enabled = false },
    };
    try std.testing.expect(!transform.requiresPreparation());
    try std.testing.expect(stabilization.requiresPreparation());
    try std.testing.expect(!disabled.requiresPreparation());
}
