const std = @import("std");
const clip_mod = @import("clip.zig");
const effect_mod = @import("../effects/effect.zig");
const media_asset = @import("media_asset.zig");
const time = @import("time.zig");
const timeline_mod = @import("timeline.zig");

pub const default_timeline_scale: u32 = 1_000_000;

pub const Error = error{
    EmptyProjectName,
    AssetNotFound,
    ClipNotFound,
    IdExhausted,
    DuplicateAssetId,
    RevisionExhausted,
} || media_asset.Error || timeline_mod.Error || std.mem.Allocator.Error;

pub const Project = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    assets: std.ArrayListUnmanaged(media_asset.MediaAsset) = .empty,
    timeline: timeline_mod.Timeline,
    next_asset_id: u64 = 1,
    next_clip_id: u64 = 1,
    revision: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        timeline_scale: u32,
    ) Error!Project {
        if (name.len == 0) return error.EmptyProjectName;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .timeline = try timeline_mod.Timeline.init(
                allocator,
                timeline_scale,
            ),
        };
    }

    pub fn deinit(self: *Project) void {
        self.timeline.deinit();
        for (self.assets.items) |*asset| asset.deinit();
        self.assets.deinit(self.allocator);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn addAsset(
        self: *Project,
        path: []const u8,
        duration: time.Time,
        has_audio: bool,
    ) Error!media_asset.AssetId {
        if (self.next_asset_id == 0) return error.IdExhausted;
        try self.ensureMutable();
        const id: media_asset.AssetId = @enumFromInt(self.next_asset_id);
        var asset = try media_asset.MediaAsset.create(
            self.allocator,
            id,
            path,
            duration,
            has_audio,
        );
        errdefer asset.deinit();
        try self.assets.append(self.allocator, asset);
        self.next_asset_id +%= 1;
        self.revision += 1;
        return id;
    }

    pub fn findAsset(
        self: *const Project,
        id: media_asset.AssetId,
    ) ?*const media_asset.MediaAsset {
        for (self.assets.items) |*asset| {
            if (asset.id == id) return asset;
        }
        return null;
    }

    pub fn appendClip(
        self: *Project,
        asset_id: media_asset.AssetId,
        timeline_start: time.Time,
        source_in: time.Time,
        source_out: time.Time,
    ) Error!clip_mod.ClipId {
        if (self.next_clip_id == 0) return error.IdExhausted;
        try self.ensureMutable();
        const asset = self.findAsset(asset_id) orelse return error.AssetNotFound;
        const id: clip_mod.ClipId = @enumFromInt(self.next_clip_id);
        var clip = try clip_mod.Clip.create(
            self.allocator,
            id,
            asset,
            timeline_start,
            source_in,
            source_out,
            self.timeline.scale,
        );
        errdefer clip.deinit();
        try self.timeline.append(clip);
        self.next_clip_id +%= 1;
        self.revision += 1;
        return id;
    }

    pub fn findClip(self: *Project, id: clip_mod.ClipId) ?*clip_mod.Clip {
        for (self.timeline.clips.items) |*clip| {
            if (clip.id == id) return clip;
        }
        return null;
    }

    pub fn setClipEffect(
        self: *Project,
        clip_id: clip_mod.ClipId,
        effect: effect_mod.Effect,
    ) Error!void {
        try self.ensureMutable();
        const clip = self.findClip(clip_id) orelse return error.ClipNotFound;
        try clip.setEffect(effect);
        self.revision += 1;
    }

    fn ensureMutable(self: *const Project) Error!void {
        if (self.revision == std.math.maxInt(u64)) {
            return error.RevisionExhausted;
        }
    }

    pub fn validate(self: *const Project) Error!void {
        if (self.name.len == 0) return error.EmptyProjectName;
        for (self.assets.items, 0..) |asset, index| {
            if (asset.path.len == 0) return error.EmptyPath;
            if (asset.duration.scale == 0) return error.InvalidScale;
            if (asset.duration.ticks <= 0) return error.InvalidDuration;
            for (self.assets.items[index + 1 ..]) |other| {
                if (asset.id == other.id) return error.DuplicateAssetId;
            }
        }
        try self.timeline.validateStructure();
        for (self.timeline.clips.items) |clip| {
            const asset = self.findAsset(clip.asset_id) orelse
                return error.AssetNotFound;
            try clip.validate(asset, self.timeline.scale);
        }
    }
};

test "project resolves ordered clips and half-open edit boundaries" {
    var project = try Project.init(
        std.testing.allocator,
        "Road trip",
        default_timeline_scale,
    );
    defer project.deinit();
    const duration = try time.Time.init(900_000, 90_000);
    const asset_id = try project.addAsset("take.mp4", duration, true);

    _ = try project.appendClip(
        asset_id,
        try time.Time.init(3_000_000, default_timeline_scale),
        try time.Time.init(270_000, 90_000),
        try time.Time.init(450_000, 90_000),
    );
    const first_id = try project.appendClip(
        asset_id,
        try time.Time.zero(default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(180_000, 90_000),
    );

    const first = (try project.timeline.resolve(
        try time.Time.init(1_999_999, default_timeline_scale),
    )).?;
    try std.testing.expectEqual(first_id, first.id);
    try std.testing.expect((try project.timeline.resolve(
        try time.Time.init(2_000_000, default_timeline_scale),
    )) == null);
    try std.testing.expectEqual(
        @as(i64, 5_000_000),
        (try project.timeline.duration()).ticks,
    );
}

test "single-track project rejects overlapping clips" {
    var project = try Project.init(
        std.testing.allocator,
        "Overlap",
        default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "take.mp4",
        try time.Time.init(900_000, 90_000),
        false,
    );
    _ = try project.appendClip(
        asset_id,
        try time.Time.zero(default_timeline_scale),
        try time.Time.zero(90_000),
        try time.Time.init(180_000, 90_000),
    );
    try std.testing.expectError(
        error.OverlappingClips,
        project.appendClip(
            asset_id,
            try time.Time.init(1_000_000, default_timeline_scale),
            try time.Time.init(180_000, 90_000),
            try time.Time.init(270_000, 90_000),
        ),
    );
}

test "project resolves a clip and its native source time" {
    var project = try Project.init(
        std.testing.allocator,
        "Resolve",
        default_timeline_scale,
    );
    defer project.deinit();
    const asset_id = try project.addAsset(
        "vfr.mov",
        try time.Time.init(900_000, 90_000),
        true,
    );
    const clip_id = try project.appendClip(
        asset_id,
        try time.Time.init(5_000_000, default_timeline_scale),
        try time.Time.init(90_000, 90_000),
        try time.Time.init(270_000, 90_000),
    );
    try project.setClipEffect(clip_id, .{ .stabilization = .{} });
    try project.validate();

    const resolved = (try project.timeline.resolvePosition(
        try time.Time.init(5_500_000, default_timeline_scale),
    )).?;
    try std.testing.expectEqual(clip_id, resolved.clip.id);
    try std.testing.expectEqual(@as(i64, 135_000), resolved.source_time.ticks);
    try std.testing.expectEqual(@as(usize, 1), resolved.clip.effects.items.len);
}
