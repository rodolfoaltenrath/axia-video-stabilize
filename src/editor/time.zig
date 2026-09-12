const std = @import("std");

pub const Error = error{
    InvalidScale,
    Overflow,
    ScaleMismatch,
};

pub const Rounding = enum {
    floor,
    nearest,
    ceil,
};

/// Exact rational time represented as `ticks / scale` seconds.
///
/// Timeline values use the project scale, while source values retain the
/// media stream's native time base. Conversion is explicit so frame mapping
/// never depends on floating-point seconds.
pub const Time = struct {
    ticks: i64,
    scale: u32,

    pub fn init(ticks: i64, scale: u32) Error!Time {
        if (scale == 0) return error.InvalidScale;
        return .{ .ticks = ticks, .scale = scale };
    }

    pub fn zero(scale: u32) Error!Time {
        return init(0, scale);
    }

    pub fn fromUnits(
        value: i64,
        unit_numerator: i32,
        unit_denominator: i32,
    ) Error!Time {
        if (unit_numerator <= 0 or unit_denominator <= 0) {
            return error.InvalidScale;
        }
        return .{
            .ticks = std.math.mul(
                i64,
                value,
                @as(i64, unit_numerator),
            ) catch return error.Overflow,
            .scale = @intCast(unit_denominator),
        };
    }

    /// Converts this time to units described by `numerator / denominator`
    /// seconds, such as an FFmpeg stream time base.
    pub fn toUnits(
        self: Time,
        unit_numerator: i32,
        unit_denominator: i32,
        rounding: Rounding,
    ) Error!i64 {
        if (self.scale == 0 or unit_numerator <= 0 or unit_denominator <= 0) {
            return error.InvalidScale;
        }
        const numerator = @as(i128, self.ticks) *
            @as(i128, unit_denominator);
        const denominator = @as(i128, self.scale) *
            @as(i128, unit_numerator);
        const converted = switch (rounding) {
            .floor => @divFloor(numerator, denominator),
            .ceil => -@divFloor(-numerator, denominator),
            .nearest => if (numerator >= 0)
                @divTrunc(numerator + @divTrunc(denominator, 2), denominator)
            else
                @divTrunc(numerator - @divTrunc(denominator, 2), denominator),
        };
        return std.math.cast(i64, converted) orelse error.Overflow;
    }

    pub fn compare(self: Time, other: Time) std.math.Order {
        std.debug.assert(self.scale != 0 and other.scale != 0);
        const left = @as(i128, self.ticks) * @as(i128, other.scale);
        const right = @as(i128, other.ticks) * @as(i128, self.scale);
        return std.math.order(left, right);
    }

    pub fn add(self: Time, other: Time) Error!Time {
        if (self.scale == 0 or other.scale == 0) return error.InvalidScale;
        if (self.scale != other.scale) return error.ScaleMismatch;
        return .{
            .ticks = std.math.add(i64, self.ticks, other.ticks) catch
                return error.Overflow,
            .scale = self.scale,
        };
    }

    pub fn subtract(self: Time, other: Time) Error!Time {
        if (self.scale == 0 or other.scale == 0) return error.InvalidScale;
        if (self.scale != other.scale) return error.ScaleMismatch;
        return .{
            .ticks = std.math.sub(i64, self.ticks, other.ticks) catch
                return error.Overflow,
            .scale = self.scale,
        };
    }

    pub fn rescale(self: Time, target_scale: u32, rounding: Rounding) Error!Time {
        if (self.scale == 0 or target_scale == 0) return error.InvalidScale;
        const numerator = @as(i128, self.ticks) * @as(i128, target_scale);
        const denominator = @as(i128, self.scale);
        const converted = switch (rounding) {
            .floor => @divFloor(numerator, denominator),
            .ceil => -@divFloor(-numerator, denominator),
            .nearest => if (numerator >= 0)
                @divTrunc(numerator + @divTrunc(denominator, 2), denominator)
            else
                @divTrunc(numerator - @divTrunc(denominator, 2), denominator),
        };
        return .{
            .ticks = std.math.cast(i64, converted) orelse
                return error.Overflow,
            .scale = target_scale,
        };
    }
};

test "rational times compare without floating point" {
    const one_second = try Time.init(90_000, 90_000);
    const also_one_second = try Time.init(1_000_000, 1_000_000);
    const later = try Time.init(1_000_001, 1_000_000);
    try std.testing.expectEqual(std.math.Order.eq, one_second.compare(also_one_second));
    try std.testing.expectEqual(std.math.Order.lt, one_second.compare(later));
}

test "time rescaling has explicit rounding" {
    const source = try Time.init(1, 3);
    try std.testing.expectEqual(@as(i64, 333), (try source.rescale(1000, .floor)).ticks);
    try std.testing.expectEqual(@as(i64, 333), (try source.rescale(1000, .nearest)).ticks);
    try std.testing.expectEqual(@as(i64, 334), (try source.rescale(1000, .ceil)).ticks);
}

test "negative rescaling rounds in the requested direction" {
    const source = try Time.init(-1, 3);
    try std.testing.expectEqual(@as(i64, -334), (try source.rescale(1000, .floor)).ticks);
    try std.testing.expectEqual(@as(i64, -333), (try source.rescale(1000, .ceil)).ticks);
}

test "media time bases retain non-unit numerators" {
    const value = try Time.fromUnits(25, 2, 1000);
    try std.testing.expectEqual(@as(i64, 50), value.ticks);
    try std.testing.expectEqual(@as(u32, 1000), value.scale);
    try std.testing.expectEqual(@as(i64, 25), try value.toUnits(2, 1000, .nearest));
}

test "time converts to media units with explicit rounding" {
    const value = try Time.init(1, 24);
    try std.testing.expectEqual(@as(i64, 41), try value.toUnits(1, 1000, .floor));
    try std.testing.expectEqual(@as(i64, 42), try value.toUnits(1, 1000, .nearest));
    try std.testing.expectEqual(@as(i64, 42), try value.toUnits(1, 1000, .ceil));
}
