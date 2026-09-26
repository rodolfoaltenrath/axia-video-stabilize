const std = @import("std");
const effect_mod = @import("../effects/effect.zig");
const media_asset = @import("media_asset.zig");
const time = @import("time.zig");

pub const ClipId = enum(u64) {
    _,
};

pub const Error = error{
    AssetMismatch,
    InvalidTimelinePosition,
    InvalidSourceRange,
    SourceRangeOutsideAsset,
    TimelineDurationMismatch,
    DuplicateEffect,
} || time.Error || effect_mod.Error || std.mem.Allocator.Error;

pub const Clip = struct {
    allocator: std.mem.Allocator,
    id: ClipId,
    asset_id: media_asset.AssetId,
    timeline_start: time.Time,
    timeline_duration: time.Time,
    source_in: time.Time,
    source_out: time.Time,
    effects: std.ArrayListUnmanaged(effect_mod.Effect) = .empty,

    pub fn create(
        allocator: std.mem.Allocator,
        id: ClipId,
        asset: *const media_asset.MediaAsset,
        timeline_start: time.Time,
        source_in: time.Time,
        source_out: time.Time,
        timeline_scale: u32,
    ) Error!Clip {
        if (timeline_scale == 0 or timeline_start.scale == 0 or
            source_in.scale == 0 or source_out.scale == 0)
        {
            return error.InvalidScale;
        }
        if (timeline_start.scale != timeline_scale) return error.ScaleMismatch;
        if (timeline_start.ticks < 0) return error.InvalidTimelinePosition;
        if (source_in.scale != asset.duration.scale or
            source_out.scale != asset.duration.scale)
        {
            return error.ScaleMismatch;
        }
        if (source_in.ticks < 0 or source_out.compare(source_in) != .gt) {
            return error.InvalidSourceRange;
        }
        if (source_out.compare(asset.duration) == .gt) {
            return error.SourceRangeOutsideAsset;
        }
        const source_duration = try source_out.subtract(source_in);
        const timeline_duration = try source_duration.rescale(
            timeline_scale,
            .nearest,
        );
        if (timeline_duration.ticks <= 0) return error.InvalidSourceRange;
        return .{
            .allocator = allocator,
            .id = id,
            .asset_id = asset.id,
            .timeline_start = timeline_start,
            .timeline_duration = timeline_duration,
            .source_in = source_in,
            .source_out = source_out,
        };
    }

    pub fn deinit(self: *Clip) void {
        self.effects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setEffect(
        self: *Clip,
        new_effect: effect_mod.Effect,
    ) Error!void {
        try new_effect.validate();
        for (self.effects.items) |*existing| {
            if (existing.kind() == new_effect.kind()) {
                existing.* = new_effect;
                return;
            }
        }
        try self.effects.append(self.allocator, new_effect);
    }

    pub fn validateTimeline(self: Clip, timeline_scale: u32) Error!void {
        if (timeline_scale == 0 or self.timeline_start.scale == 0 or
            self.timeline_duration.scale == 0 or self.source_in.scale == 0 or
            self.source_out.scale == 0)
        {
            return error.InvalidScale;
        }
        if (self.timeline_start.scale != timeline_scale or
            self.timeline_duration.scale != timeline_scale)
        {
            return error.ScaleMismatch;
        }
        if (self.timeline_start.ticks < 0 or self.timeline_duration.ticks <= 0) {
            return error.InvalidTimelinePosition;
        }
        if (self.source_in.scale != self.source_out.scale or
            self.source_in.ticks < 0 or
            self.source_out.compare(self.source_in) != .gt)
        {
            return error.InvalidSourceRange;
        }
        const source_duration = try self.source_out.subtract(self.source_in);
        const expected_duration = try source_duration.rescale(
            timeline_scale,
            .nearest,
        );
        if (expected_duration.ticks != self.timeline_duration.ticks) {
            return error.TimelineDurationMismatch;
        }
        for (self.effects.items, 0..) |effect, index| {
            try effect.validate();
            for (self.effects.items[index + 1 ..]) |other| {
                if (effect.kind() == other.kind()) return error.DuplicateEffect;
            }
        }
    }

    pub fn validate(
        self: Clip,
        asset: *const media_asset.MediaAsset,
        timeline_scale: u32,
    ) Error!void {
        try self.validateTimeline(timeline_scale);
        if (self.asset_id != asset.id) return error.AssetMismatch;
        if (self.source_in.scale != asset.duration.scale) {
            return error.ScaleMismatch;
        }
        if (self.source_out.compare(asset.duration) == .gt) {
            return error.SourceRangeOutsideAsset;
        }
    }

    pub fn timelineEnd(self: Clip) Error!time.Time {
        return self.timeline_start.add(self.timeline_duration);
    }

    pub fn contains(self: Clip, position: time.Time) Error!bool {
        if (position.scale != self.timeline_start.scale) {
            return error.ScaleMismatch;
        }
        return position.compare(self.timeline_start) != .lt and
            position.compare(try self.timelineEnd()) == .lt;
    }

    pub fn sourceTimeAt(self: Clip, position: time.Time) Error!time.Time {
        if (!try self.contains(position)) return error.InvalidTimelinePosition;
        const timeline_offset = try position.subtract(self.timeline_start);
        const source_offset = try timeline_offset.rescale(
            self.source_in.scale,
            .floor,
        );
        return self.source_in.add(source_offset);
    }
};

test "clip maps timeline positions to source timestamps" {
    var asset = try media_asset.MediaAsset.create(
        std.testing.allocator,
        @enumFromInt(1),
        "take.mp4",
        try time.Time.init(900_000, 90_000),
        true,
    );
    defer asset.deinit();
    var value = try Clip.create(
        std.testing.allocator,
        @enumFromInt(1),
        &asset,
        try time.Time.init(2_000_000, 1_000_000),
        try time.Time.init(90_000, 90_000),
        try time.Time.init(360_000, 90_000),
        1_000_000,
    );
    defer value.deinit();
    const source_time = try value.sourceTimeAt(
        try time.Time.init(3_500_000, 1_000_000),
    );
    try std.testing.expectEqual(@as(i64, 225_000), source_time.ticks);
}

test "clip owns one replaceable instance of each effect kind" {
    var asset = try media_asset.MediaAsset.create(
        std.testing.allocator,
        @enumFromInt(1),
        "take.mp4",
        try time.Time.init(90_000, 90_000),
        false,
    );
    defer asset.deinit();
    var value = try Clip.create(
        std.testing.allocator,
        @enumFromInt(1),
        &asset,
        try time.Time.zero(1_000_000),
        try time.Time.zero(90_000),
        asset.duration,
        1_000_000,
    );
    defer value.deinit();
    try value.setEffect(.{ .stabilization = .{} });
    try value.setEffect(.{
        .stabilization = .{ .smoothness_percent = 50 },
    });
    try std.testing.expectEqual(@as(usize, 1), value.effects.items.len);
    try std.testing.expectEqual(
        @as(f32, 50),
        value.effects.items[0].stabilization.smoothness_percent,
    );
}
