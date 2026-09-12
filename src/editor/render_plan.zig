const std = @import("std");
const effect_mod = @import("../effects/effect.zig");
const snapshot_mod = @import("project_snapshot.zig");
const time = @import("time.zig");

pub const Error = error{
    AssetNotFound,
    InvalidFrameRate,
} || snapshot_mod.Error;

pub const FrameRate = struct {
    numerator: u32,
    denominator: u32,

    pub fn validate(self: FrameRate) Error!void {
        if (self.numerator == 0 or self.denominator == 0) {
            return error.InvalidFrameRate;
        }
    }
};

pub const FrameRequest = struct {
    asset: *const snapshot_mod.Asset,
    clip: *const snapshot_mod.Clip,
    timeline_time: time.Time,
    source_time: time.Time,
    effects: []const effect_mod.Effect,
};

pub const ScheduledFrame = struct {
    index: u64,
    timeline_time: time.Time,
    request: ?FrameRequest,
};

pub const PreparationRequest = struct {
    kind: effect_mod.PreparationKind,
    asset: *const snapshot_mod.Asset,
    clip: *const snapshot_mod.Clip,
    effect_index: usize,
    effect: *const effect_mod.Effect,

    pub fn identity(self: PreparationRequest) PreparationIdentity {
        return .{
            .asset_id = @intFromEnum(self.asset.id),
            .clip_id = @intFromEnum(self.clip.id),
            .kind = self.kind,
            .source_in = self.clip.source_in,
            .source_out = self.clip.source_out,
        };
    }
};

/// Stable logical identity for a prepared artifact. The future cache will add
/// a media fingerprint and effect-parameter digest to this value.
pub const PreparationIdentity = struct {
    asset_id: u64,
    clip_id: u64,
    kind: effect_mod.PreparationKind,
    source_in: time.Time,
    source_out: time.Time,
};

pub const PreparationIterator = struct {
    snapshot: *const snapshot_mod.ProjectSnapshot,
    clip_index: usize = 0,
    effect_index: usize = 0,

    pub fn next(self: *PreparationIterator) Error!?PreparationRequest {
        while (self.clip_index < self.snapshot.clips.len) {
            const clip = &self.snapshot.clips[self.clip_index];
            while (self.effect_index < clip.effects.len) {
                const index = self.effect_index;
                self.effect_index += 1;
                const effect = &clip.effects[index];
                const kind = effect.preparationKind() orelse continue;
                const asset = self.snapshot.findAsset(clip.asset_id) orelse
                    return error.AssetNotFound;
                return .{
                    .kind = kind,
                    .asset = asset,
                    .clip = clip,
                    .effect_index = index,
                    .effect = effect,
                };
            }
            self.clip_index += 1;
            self.effect_index = 0;
        }
        return null;
    }
};

pub const FrameIterator = struct {
    plan: RenderPlan,
    rate: FrameRate,
    end: time.Time,
    next_index: u64 = 0,

    pub fn next(self: *FrameIterator) Error!?ScheduledFrame {
        const index = self.next_index;
        const scaled_index = std.math.mul(
            u128,
            @as(u128, index),
            @as(u128, self.plan.snapshot.timeline_scale),
        ) catch return error.Overflow;
        const numerator = std.math.mul(
            u128,
            scaled_index,
            @as(u128, self.rate.denominator),
        ) catch return error.Overflow;
        const ticks = numerator / @as(u128, self.rate.numerator);
        const position = try time.Time.init(
            std.math.cast(i64, ticks) orelse return error.Overflow,
            self.plan.snapshot.timeline_scale,
        );
        if (position.compare(self.end) != .lt) return null;
        self.next_index = std.math.add(u64, index, 1) catch
            return error.Overflow;
        return .{
            .index = index,
            .timeline_time = position,
            .request = try self.plan.resolve(position),
        };
    }
};

pub const RenderPlan = struct {
    snapshot: *const snapshot_mod.ProjectSnapshot,

    pub fn init(snapshot: *const snapshot_mod.ProjectSnapshot) RenderPlan {
        return .{ .snapshot = snapshot };
    }

    pub fn resolve(
        self: RenderPlan,
        position: time.Time,
    ) Error!?FrameRequest {
        if (position.scale != self.snapshot.timeline_scale) {
            return error.ScaleMismatch;
        }
        for (self.snapshot.clips) |*clip| {
            if (try clip.contains(position)) {
                const asset = self.snapshot.findAsset(clip.asset_id) orelse
                    return error.AssetNotFound;
                return .{
                    .asset = asset,
                    .clip = clip,
                    .timeline_time = position,
                    .source_time = try clip.sourceTimeAt(position),
                    .effects = clip.effects,
                };
            }
            if (position.compare(clip.timeline_start) == .lt) break;
        }
        return null;
    }

    pub fn preparations(self: RenderPlan) PreparationIterator {
        return .{ .snapshot = self.snapshot };
    }

    pub fn frames(self: RenderPlan, rate: FrameRate) Error!FrameIterator {
        try rate.validate();
        const end = if (self.snapshot.clips.len == 0)
            try time.Time.zero(self.snapshot.timeline_scale)
        else
            try self.snapshot.clips[self.snapshot.clips.len - 1].timelineEnd();
        return .{ .plan = self, .rate = rate, .end = end };
    }
};

test "render plan resolves immutable media, source time and effect order" {
    const project_mod = @import("project.zig");
    var project = try project_mod.Project.init(
        std.testing.allocator,
        "Render",
        project_mod.default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "take.mov",
        try time.Time.init(900_000, 90_000),
        true,
    );
    const clip_id = try project.appendClip(
        asset_id,
        try time.Time.init(2_000_000, project_mod.default_timeline_scale),
        try time.Time.init(90_000, 90_000),
        try time.Time.init(270_000, 90_000),
    );
    try project.setClipEffect(clip_id, .{ .transform = .{} });
    try project.setClipEffect(clip_id, .{ .stabilization = .{} });
    var snapshot = try snapshot_mod.ProjectSnapshot.create(
        std.testing.allocator,
        &project,
    );
    defer snapshot.deinit();
    const plan = RenderPlan.init(&snapshot);

    const request = (try plan.resolve(
        try time.Time.init(2_500_000, project_mod.default_timeline_scale),
    )).?;
    try std.testing.expectEqualStrings("take.mov", request.asset.path);
    try std.testing.expectEqual(@as(i64, 135_000), request.source_time.ticks);
    try std.testing.expectEqual(@as(usize, 2), request.effects.len);
    try std.testing.expect((try plan.resolve(
        try time.Time.init(4_000_000, project_mod.default_timeline_scale),
    )) == null);
}

test "preparation iterator returns only enabled temporal effects" {
    const project_mod = @import("project.zig");
    var project = try project_mod.Project.init(
        std.testing.allocator,
        "Prepare",
        project_mod.default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "take.mp4",
        try time.Time.init(180_000, 90_000),
        false,
    );
    const clip_id = try project.appendClip(
        asset_id,
        try time.Time.zero(project_mod.default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(90_000, 90_000),
    );
    try project.setClipEffect(clip_id, .{ .transform = .{} });
    try project.setClipEffect(clip_id, .{ .stabilization = .{} });
    const disabled_clip_id = try project.appendClip(
        asset_id,
        try time.Time.init(1_000_000, project_mod.default_timeline_scale),
        try time.Time.init(90_000, 90_000),
        try time.Time.init(180_000, 90_000),
    );
    try project.setClipEffect(disabled_clip_id, .{
        .stabilization = .{ .enabled = false },
    });
    var snapshot = try snapshot_mod.ProjectSnapshot.create(
        std.testing.allocator,
        &project,
    );
    defer snapshot.deinit();
    var iterator = RenderPlan.init(&snapshot).preparations();

    const request = (try iterator.next()).?;
    try std.testing.expectEqual(
        effect_mod.PreparationKind.stabilization_analysis,
        request.kind,
    );
    try std.testing.expectEqual(clip_id, request.clip.id);
    try std.testing.expectEqual(@intFromEnum(asset_id), request.identity().asset_id);
    try std.testing.expect((try iterator.next()) == null);
}

test "frame iterator derives rational positions without accumulated drift" {
    const project_mod = @import("project.zig");
    var project = try project_mod.Project.init(
        std.testing.allocator,
        "Frame schedule",
        project_mod.default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "take.mp4",
        try time.Time.init(180_000, 90_000),
        false,
    );
    _ = try project.appendClip(
        asset_id,
        try time.Time.zero(project_mod.default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(180_000, 90_000),
    );
    var snapshot = try snapshot_mod.ProjectSnapshot.create(
        std.testing.allocator,
        &project,
    );
    defer snapshot.deinit();
    var frames = try RenderPlan.init(&snapshot).frames(.{
        .numerator = 30_000,
        .denominator = 1_001,
    });

    var frame: ScheduledFrame = undefined;
    for (0..31) |_| frame = (try frames.next()).?;
    try std.testing.expectEqual(@as(u64, 30), frame.index);
    try std.testing.expectEqual(@as(i64, 1_001_000), frame.timeline_time.ticks);
    try std.testing.expect(frame.request != null);
}
