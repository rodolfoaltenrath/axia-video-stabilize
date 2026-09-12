const std = @import("std");
const render_plan = @import("../editor/render_plan.zig");
const media_asset = @import("../editor/media_asset.zig");
const editor_time = @import("../editor/time.zig");
const decoder_mod = @import("decoder.zig");

pub const Error = error{
    RequestAssetMismatch,
    FrameNotFound,
    TimestampBeforeRequest,
    PixelFormatMismatch,
} || decoder_mod.DecoderError || editor_time.Error;

pub const DecodedFrame = struct {
    request: render_plan.FrameRequest,
    frame: decoder_mod.FrameView,
};

/// Owns the decoder used by timeline preview or export. The active decoder is
/// reused while consecutive requests reference the same immutable asset and
/// replaced only when the timeline crosses into another asset.
pub fn CursorFor(comptime Backend: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        options: decoder_mod.Options,
        active_asset_id: ?media_asset.AssetId = null,
        active: ?Backend = null,
        last_request_time: ?editor_time.Time = null,
        last_frame: ?decoder_mod.FrameView = null,

        pub fn init(
            allocator: std.mem.Allocator,
            options: decoder_mod.Options,
        ) Self {
            return .{
                .allocator = allocator,
                .options = options,
            };
        }

        pub fn deinit(self: *Self) void {
            self.closeActive();
            self.* = undefined;
        }

        /// Returns pixels for the first source frame at or after the resolved
        /// source timestamp. The returned pixels remain valid until the next
        /// cursor read, asset switch or deinit.
        pub fn read(
            self: *Self,
            request: render_plan.FrameRequest,
        ) Error!DecodedFrame {
            if (request.clip.asset_id != request.asset.id) {
                return error.RequestAssetMismatch;
            }
            try self.ensureAsset(request);
            const frame = try self.frameAtOrAfter(request.source_time);
            if (frame.format != self.options.output_format) {
                return error.PixelFormatMismatch;
            }
            const frame_time = try timeOf(frame);
            if (frame_time.compare(request.source_time) == .lt) {
                return error.TimestampBeforeRequest;
            }
            self.last_request_time = request.source_time;
            self.last_frame = frame;
            return .{ .request = request, .frame = frame };
        }

        fn frameAtOrAfter(
            self: *Self,
            target: editor_time.Time,
        ) Error!decoder_mod.FrameView {
            if (self.last_request_time) |last_request| {
                if (target.compare(last_request) != .lt) {
                    if (self.last_frame) |last_frame| {
                        const last_frame_time = try timeOf(last_frame);
                        if (target.compare(last_frame_time) != .gt) {
                            return last_frame;
                        }
                        if (withinSequentialWindow(last_frame_time, target)) {
                            while (try self.active.?.readFrame()) |frame| {
                                if ((try timeOf(frame)).compare(target) != .lt) {
                                    return frame;
                                }
                            }
                            return error.FrameNotFound;
                        }
                    }
                }
            }
            return (try self.active.?.readFrameAtOrAfter(target)) orelse
                error.FrameNotFound;
        }

        fn ensureAsset(
            self: *Self,
            request: render_plan.FrameRequest,
        ) Error!void {
            if (self.active_asset_id == request.asset.id and self.active != null) {
                return;
            }
            self.closeActive();
            self.active = try Backend.open(
                self.allocator,
                request.asset.path,
                self.options,
            );
            self.active_asset_id = request.asset.id;
        }

        fn closeActive(self: *Self) void {
            if (self.active) |*active| active.deinit();
            self.active = null;
            self.active_asset_id = null;
            self.last_request_time = null;
            self.last_frame = null;
        }
    };
}

pub const ProjectDecoder = CursorFor(decoder_mod.Decoder);

const TestDecoder = struct {
    format: decoder_mod.PixelFormat,
    pts: i64 = 0,

    var open_count: usize = 0;
    var close_count: usize = 0;
    var seek_count: usize = 0;
    var sequential_read_count: usize = 0;
    var pixels = [_]u8{ 0, 0, 0, 255 };

    fn reset() void {
        open_count = 0;
        close_count = 0;
        seek_count = 0;
        sequential_read_count = 0;
    }

    pub fn open(
        _: std.mem.Allocator,
        _: []const u8,
        options: decoder_mod.Options,
    ) decoder_mod.DecoderError!TestDecoder {
        open_count += 1;
        return .{ .format = options.output_format };
    }

    pub fn deinit(_: *TestDecoder) void {
        close_count += 1;
    }

    pub fn readFrameAtOrAfter(
        self: *TestDecoder,
        target: editor_time.Time,
    ) Error!?decoder_mod.FrameView {
        seek_count += 1;
        self.pts = try target.toUnits(1, 90_000, .ceil);
        return self.currentFrame();
    }

    pub fn readFrame(self: *TestDecoder) Error!?decoder_mod.FrameView {
        sequential_read_count += 1;
        self.pts += 3_000;
        return self.currentFrame();
    }

    fn currentFrame(self: *TestDecoder) decoder_mod.FrameView {
        return .{
            .timing = .{
                .index = 0,
                .pts = self.pts,
                .time_base = .{ .numerator = 1, .denominator = 90_000 },
            },
            .pixels = &pixels,
            .width = 1,
            .height = 1,
            .stride = 4,
            .format = self.format,
        };
    }
};

fn timeOf(frame: decoder_mod.FrameView) editor_time.Error!editor_time.Time {
    return editor_time.Time.fromUnits(
        frame.timing.pts,
        frame.timing.time_base.numerator,
        frame.timing.time_base.denominator,
    );
}

fn withinSequentialWindow(
    current: editor_time.Time,
    target: editor_time.Time,
) bool {
    const one_second_later_ticks = std.math.add(
        i64,
        current.ticks,
        @as(i64, current.scale),
    ) catch return false;
    return target.compare(.{
        .ticks = one_second_later_ticks,
        .scale = current.scale,
    }) != .gt;
}

test "project decoder reuses an asset and switches at a cut" {
    const snapshot_mod = @import("../editor/project_snapshot.zig");
    const clip_mod = @import("../editor/clip.zig");
    TestDecoder.reset();
    var cursor = CursorFor(TestDecoder).init(
        std.testing.allocator,
        .{ .output_format = .bgra8 },
    );
    defer cursor.deinit();

    const first_asset = snapshot_mod.Asset{
        .id = @enumFromInt(1),
        .path = "first.mp4",
        .duration = try editor_time.Time.init(180_000, 90_000),
        .has_audio = true,
    };
    const second_asset = snapshot_mod.Asset{
        .id = @enumFromInt(2),
        .path = "second.mp4",
        .duration = first_asset.duration,
        .has_audio = false,
    };
    const effects = [_]@import("../effects/effect.zig").Effect{};
    const clip = snapshot_mod.Clip{
        .id = @as(clip_mod.ClipId, @enumFromInt(1)),
        .asset_id = first_asset.id,
        .timeline_start = try editor_time.Time.zero(1_000_000),
        .timeline_duration = try editor_time.Time.init(1_000_000, 1_000_000),
        .source_in = try editor_time.Time.zero(90_000),
        .source_out = try editor_time.Time.init(90_000, 90_000),
        .effects = &effects,
    };
    const second_clip = snapshot_mod.Clip{
        .id = @as(clip_mod.ClipId, @enumFromInt(2)),
        .asset_id = second_asset.id,
        .timeline_start = try editor_time.Time.init(1_000_000, 1_000_000),
        .timeline_duration = try editor_time.Time.init(1_000_000, 1_000_000),
        .source_in = try editor_time.Time.zero(90_000),
        .source_out = try editor_time.Time.init(90_000, 90_000),
        .effects = &effects,
    };
    const source_time = try editor_time.Time.init(45_000, 90_000);
    var request = render_plan.FrameRequest{
        .asset = &first_asset,
        .clip = &clip,
        .timeline_time = try editor_time.Time.init(500_000, 1_000_000),
        .source_time = source_time,
        .effects = clip.effects,
    };

    const first = try cursor.read(request);
    _ = try cursor.read(request);
    try std.testing.expectEqual(@as(i64, 45_000), first.frame.timing.pts);
    try std.testing.expectEqual(@as(usize, 1), TestDecoder.open_count);
    try std.testing.expectEqual(@as(usize, 0), TestDecoder.close_count);
    try std.testing.expectEqual(@as(usize, 1), TestDecoder.seek_count);

    request.source_time = try editor_time.Time.init(46_000, 90_000);
    const sequential = try cursor.read(request);
    try std.testing.expectEqual(@as(i64, 48_000), sequential.frame.timing.pts);
    try std.testing.expectEqual(@as(usize, 1), TestDecoder.seek_count);
    try std.testing.expectEqual(@as(usize, 1), TestDecoder.sequential_read_count);

    request.asset = &second_asset;
    request.clip = &second_clip;
    _ = try cursor.read(request);
    try std.testing.expectEqual(@as(usize, 2), TestDecoder.open_count);
    try std.testing.expectEqual(@as(usize, 1), TestDecoder.close_count);
}
