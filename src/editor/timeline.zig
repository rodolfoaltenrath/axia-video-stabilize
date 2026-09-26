const std = @import("std");
const clip_mod = @import("clip.zig");
const time = @import("time.zig");

pub const Error = error{
    DuplicateClipId,
    OverlappingClips,
    InvalidTimelineScale,
    ClipsNotOrdered,
} || clip_mod.Error || std.mem.Allocator.Error;

pub const ResolvedPosition = struct {
    clip: *const clip_mod.Clip,
    source_time: time.Time,
};

/// The first editor milestone intentionally models one non-overlapping video
/// track. Additional tracks can later compose through the render pipeline
/// without weakening these clip timing guarantees.
pub const Timeline = struct {
    allocator: std.mem.Allocator,
    scale: u32,
    clips: std.ArrayListUnmanaged(clip_mod.Clip) = .empty,

    pub fn init(allocator: std.mem.Allocator, scale: u32) Error!Timeline {
        if (scale == 0) return error.InvalidTimelineScale;
        return .{ .allocator = allocator, .scale = scale };
    }

    pub fn deinit(self: *Timeline) void {
        for (self.clips.items) |*clip| clip.deinit();
        self.clips.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Timeline, new_clip: clip_mod.Clip) Error!void {
        try new_clip.validateTimeline(self.scale);
        const new_end = try new_clip.timelineEnd();
        for (self.clips.items) |existing| {
            if (existing.id == new_clip.id) return error.DuplicateClipId;
            const existing_end = try existing.timelineEnd();
            const separated = new_end.compare(existing.timeline_start) != .gt or
                new_clip.timeline_start.compare(existing_end) != .lt;
            if (!separated) return error.OverlappingClips;
        }
        try self.clips.append(self.allocator, new_clip);
        std.mem.sort(clip_mod.Clip, self.clips.items, {}, lessThan);
    }

    pub fn resolve(self: *const Timeline, position: time.Time) Error!?*const clip_mod.Clip {
        if (position.scale != self.scale) return error.ScaleMismatch;
        for (self.clips.items) |*clip| {
            if (try clip.contains(position)) return clip;
            if (position.compare(clip.timeline_start) == .lt) break;
        }
        return null;
    }

    pub fn resolvePosition(
        self: *const Timeline,
        position: time.Time,
    ) Error!?ResolvedPosition {
        const clip = try self.resolve(position) orelse return null;
        return .{
            .clip = clip,
            .source_time = try clip.sourceTimeAt(position),
        };
    }

    pub fn duration(self: *const Timeline) Error!time.Time {
        var result = try time.Time.zero(self.scale);
        for (self.clips.items) |clip| {
            const end = try clip.timelineEnd();
            if (end.compare(result) == .gt) result = end;
        }
        return result;
    }

    pub fn validateStructure(self: *const Timeline) Error!void {
        if (self.scale == 0) return error.InvalidTimelineScale;
        for (self.clips.items, 0..) |clip, index| {
            try clip.validateTimeline(self.scale);
            for (self.clips.items[index + 1 ..]) |other| {
                if (clip.id == other.id) return error.DuplicateClipId;
                if (clip.timeline_start.compare(other.timeline_start) == .gt) {
                    return error.ClipsNotOrdered;
                }
                const clip_end = try clip.timelineEnd();
                if (clip_end.compare(other.timeline_start) == .gt) {
                    return error.OverlappingClips;
                }
            }
        }
    }

    fn lessThan(_: void, left: clip_mod.Clip, right: clip_mod.Clip) bool {
        return left.timeline_start.compare(right.timeline_start) == .lt;
    }
};
