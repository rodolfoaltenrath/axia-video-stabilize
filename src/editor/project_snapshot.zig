const std = @import("std");
const clip_mod = @import("clip.zig");
const effect_mod = @import("../effects/effect.zig");
const media_asset = @import("media_asset.zig");
const project_mod = @import("project.zig");
const time = @import("time.zig");

pub const Error = error{InvalidTimelinePosition} || time.Error;

pub const Asset = struct {
    id: media_asset.AssetId,
    path: [:0]const u8,
    duration: time.Time,
    has_audio: bool,
};

pub const Clip = struct {
    id: clip_mod.ClipId,
    asset_id: media_asset.AssetId,
    timeline_start: time.Time,
    timeline_duration: time.Time,
    source_in: time.Time,
    source_out: time.Time,
    effects: []const effect_mod.Effect,

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
        const offset = try position.subtract(self.timeline_start);
        return self.source_in.add(try offset.rescale(
            self.source_in.scale,
            .floor,
        ));
    }
};

/// Deep, read-only copy passed to preview and export workers. All slices point
/// to storage owned by the snapshot and remain stable until `deinit`.
pub const ProjectSnapshot = struct {
    allocator: std.mem.Allocator,
    revision: u64,
    name: []const u8,
    timeline_scale: u32,
    assets: []const Asset,
    clips: []const Clip,

    pub fn create(
        allocator: std.mem.Allocator,
        source: *const project_mod.Project,
    ) (project_mod.Error || std.mem.Allocator.Error)!ProjectSnapshot {
        try source.validate();
        const name = try allocator.dupe(u8, source.name);
        errdefer allocator.free(name);

        const assets = try allocator.alloc(Asset, source.assets.items.len);
        var initialized_assets: usize = 0;
        errdefer {
            for (assets[0..initialized_assets]) |asset| allocator.free(asset.path);
            allocator.free(assets);
        }
        for (source.assets.items, 0..) |asset, index| {
            const path = try allocator.dupeZ(u8, asset.path);
            assets[index] = .{
                .id = asset.id,
                .path = path,
                .duration = asset.duration,
                .has_audio = asset.has_audio,
            };
            initialized_assets += 1;
        }

        const clips = try allocator.alloc(Clip, source.timeline.clips.items.len);
        var initialized_clips: usize = 0;
        errdefer {
            for (clips[0..initialized_clips]) |clip| allocator.free(clip.effects);
            allocator.free(clips);
        }
        for (source.timeline.clips.items, 0..) |clip, index| {
            const effects = try allocator.dupe(effect_mod.Effect, clip.effects.items);
            clips[index] = .{
                .id = clip.id,
                .asset_id = clip.asset_id,
                .timeline_start = clip.timeline_start,
                .timeline_duration = clip.timeline_duration,
                .source_in = clip.source_in,
                .source_out = clip.source_out,
                .effects = effects,
            };
            initialized_clips += 1;
        }

        return .{
            .allocator = allocator,
            .revision = source.revision,
            .name = name,
            .timeline_scale = source.timeline.scale,
            .assets = assets,
            .clips = clips,
        };
    }

    pub fn deinit(self: *ProjectSnapshot) void {
        for (self.clips) |clip| self.allocator.free(clip.effects);
        self.allocator.free(self.clips);
        for (self.assets) |asset| self.allocator.free(asset.path);
        self.allocator.free(self.assets);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn findAsset(self: *const ProjectSnapshot, id: media_asset.AssetId) ?*const Asset {
        for (self.assets) |*asset| {
            if (asset.id == id) return asset;
        }
        return null;
    }

    pub fn findClip(self: *const ProjectSnapshot, id: clip_mod.ClipId) ?*const Clip {
        for (self.clips) |*clip| {
            if (clip.id == id) return clip;
        }
        return null;
    }
};

test "snapshot deeply owns project media and effect state" {
    var project = try project_mod.Project.init(
        std.testing.allocator,
        "Original",
        project_mod.default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "source.mp4",
        try time.Time.init(900_000, 90_000),
        true,
    );
    const clip_id = try project.appendClip(
        asset_id,
        try time.Time.zero(project_mod.default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(90_000, 90_000),
    );
    try project.setClipEffect(clip_id, .{ .stabilization = .{} });
    var snapshot = try ProjectSnapshot.create(std.testing.allocator, &project);
    defer snapshot.deinit();
    const captured_revision = project.revision;

    project.name[0] = 'X';
    project.assets.items[0].path[0] = 'X';
    try project.setClipEffect(clip_id, .{
        .stabilization = .{ .smoothness_percent = 20 },
    });

    try std.testing.expectEqualStrings("Original", snapshot.name);
    try std.testing.expectEqualStrings("source.mp4", snapshot.assets[0].path);
    try std.testing.expectEqual(
        @as(f32, 72),
        snapshot.clips[0].effects[0].stabilization.smoothness_percent,
    );
    try std.testing.expectEqual(captured_revision, snapshot.revision);
    try std.testing.expect(project.revision > snapshot.revision);
}

fn createSnapshotWithFailingAllocator(
    allocator: std.mem.Allocator,
    source: *const project_mod.Project,
) !void {
    var snapshot = try ProjectSnapshot.create(allocator, source);
    defer snapshot.deinit();
}

test "snapshot creation cleans every partial allocation" {
    var project = try project_mod.Project.init(
        std.testing.allocator,
        "Allocation failures",
        project_mod.default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "source.mp4",
        try time.Time.init(180_000, 90_000),
        true,
    );
    const clip_id = try project.appendClip(
        asset_id,
        try time.Time.zero(project_mod.default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(90_000, 90_000),
    );
    try project.setClipEffect(clip_id, .{ .stabilization = .{} });

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        createSnapshotWithFailingAllocator,
        .{&project},
    );
}
