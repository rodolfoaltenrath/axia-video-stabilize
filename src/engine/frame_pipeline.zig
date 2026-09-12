const std = @import("std");
const editor_time = @import("../editor/time.zig");
const render_plan = @import("../editor/render_plan.zig");
const effect_mod = @import("../effects/effect.zig");
const warp = @import("warp.zig");

pub const PreparedError = error{
    MissingPreparedEffect,
    InvalidPreparedEffect,
};

pub const Error = PreparedError || warp.WarpError || editor_time.Error ||
    effect_mod.Error;

pub const FrameContext = struct {
    clip_id: u64,
    source_time: editor_time.Time,
    frame_index: ?usize = null,
    width: u32,
    height: u32,
};

/// Binds a timeline render request to the decoded frame supplied by a preview
/// or export worker. Both consumers therefore use the same source timestamp,
/// clip identity and ordered effect stack.
pub fn contextFromRequest(
    request: render_plan.FrameRequest,
    width: u32,
    height: u32,
    frame_index: ?usize,
) FrameContext {
    return .{
        .clip_id = @intFromEnum(request.clip.id),
        .source_time = request.source_time,
        .frame_index = frame_index,
        .width = width,
        .height = height,
    };
}

pub const StabilizationLookup = struct {
    clip_id: u64,
    effect_index: usize,
    source_time: editor_time.Time,
    frame_index: ?usize,
    width: u32,
    height: u32,
};

pub const PreparedEffects = struct {
    context: ?*anyopaque = null,
    stabilization_matrix: ?*const fn (
        ?*anyopaque,
        StabilizationLookup,
    ) PreparedError!warp.AffineMatrix = null,

    fn stabilizationMatrix(
        self: PreparedEffects,
        lookup: StabilizationLookup,
    ) PreparedError!warp.AffineMatrix {
        const callback = self.stabilization_matrix orelse
            return error.MissingPreparedEffect;
        return callback(self.context, lookup);
    }
};

/// Resolves an ordered effect stack to one input-to-output affine matrix. A
/// native renderer can therefore warp each frame once regardless of how many
/// affine effects are active.
pub fn buildMatrix(
    frame: FrameContext,
    effects: []const effect_mod.Effect,
    prepared: PreparedEffects,
) Error!warp.AffineMatrix {
    if (frame.width == 0 or frame.height == 0) {
        return error.InvalidDimensions;
    }
    var result = warp.AffineMatrix.identity();
    for (effects, 0..) |effect, effect_index| {
        if (!effect.enabled()) continue;
        try effect.validate();
        const matrix = switch (effect) {
            .transform => |transform| transformMatrix(
                transform,
                frame.width,
                frame.height,
            ),
            .stabilization => try prepared.stabilizationMatrix(.{
                .clip_id = frame.clip_id,
                .effect_index = effect_index,
                .source_time = frame.source_time,
                .frame_index = frame.frame_index,
                .width = frame.width,
                .height = frame.height,
            }),
        };
        try matrix.validate();
        result = compose(matrix, result);
    }
    try result.validate();
    return result;
}

pub fn processBgra(
    source_pixels: []const u8,
    source_stride: usize,
    destination_pixels: []u8,
    destination_stride: usize,
    frame: FrameContext,
    effects: []const effect_mod.Effect,
    prepared: PreparedEffects,
) Error!void {
    const matrix = try buildMatrix(frame, effects, prepared);
    try warp.warpBgra(
        source_pixels,
        source_stride,
        destination_pixels,
        destination_stride,
        frame.width,
        frame.height,
        matrix,
    );
}

/// Processes pixels decoded for a resolved timeline request. The decoder owns
/// timestamp seeking; this function owns effect dispatch and the single warp.
pub fn processRequestBgra(
    source_pixels: []const u8,
    source_stride: usize,
    destination_pixels: []u8,
    destination_stride: usize,
    request: render_plan.FrameRequest,
    width: u32,
    height: u32,
    frame_index: ?usize,
    prepared: PreparedEffects,
) Error!void {
    try processBgra(
        source_pixels,
        source_stride,
        destination_pixels,
        destination_stride,
        contextFromRequest(request, width, height, frame_index),
        request.effects,
        prepared,
    );
}

fn transformMatrix(
    transform: @import("../effects/transform.zig").Transform,
    width: u32,
    height: u32,
) warp.AffineMatrix {
    const cosine = @cos(transform.rotation_radians) * transform.scale;
    const sine = @sin(transform.rotation_radians) * transform.scale;
    const center_x = (@as(f64, @floatFromInt(width)) - 1.0) / 2.0;
    const center_y = (@as(f64, @floatFromInt(height)) - 1.0) / 2.0;
    return .{
        .m00 = cosine,
        .m01 = -sine,
        .m02 = transform.translation_x + center_x -
            cosine * center_x + sine * center_y,
        .m10 = sine,
        .m11 = cosine,
        .m12 = transform.translation_y + center_y -
            sine * center_x - cosine * center_y,
    };
}

/// Returns `after(before(point))`.
fn compose(
    after: warp.AffineMatrix,
    before: warp.AffineMatrix,
) warp.AffineMatrix {
    return .{
        .m00 = after.m00 * before.m00 + after.m01 * before.m10,
        .m01 = after.m00 * before.m01 + after.m01 * before.m11,
        .m02 = after.m00 * before.m02 + after.m01 * before.m12 + after.m02,
        .m10 = after.m10 * before.m00 + after.m11 * before.m10,
        .m11 = after.m10 * before.m01 + after.m11 * before.m11,
        .m12 = after.m10 * before.m02 + after.m11 * before.m12 + after.m12,
    };
}

const TestPrepared = struct {
    matrix: warp.AffineMatrix,

    fn lookup(
        raw_context: ?*anyopaque,
        _: StabilizationLookup,
    ) PreparedError!warp.AffineMatrix {
        const self: *TestPrepared = @ptrCast(@alignCast(raw_context.?));
        return self.matrix;
    }
};

test "frame pipeline composes enabled effects in stack order" {
    const effects = [_]effect_mod.Effect{
        .{ .transform = .{ .translation_x = 10, .translation_y = 5 } },
        .{ .stabilization = .{} },
    };
    var artifact = TestPrepared{ .matrix = .{
        .m00 = 2,
        .m01 = 0,
        .m02 = 0,
        .m10 = 0,
        .m11 = 2,
        .m12 = 0,
    } };
    const matrix = try buildMatrix(.{
        .clip_id = 7,
        .source_time = try editor_time.Time.zero(90_000),
        .width = 1920,
        .height = 1080,
    }, &effects, .{
        .context = &artifact,
        .stabilization_matrix = TestPrepared.lookup,
    });
    const output = matrix.apply(.{ .x = 1, .y = 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 22), output.x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 14), output.y, 0.000001);
}

test "frame pipeline requires a prepared temporal artifact" {
    const effects = [_]effect_mod.Effect{.{ .stabilization = .{} }};
    try std.testing.expectError(
        error.MissingPreparedEffect,
        buildMatrix(.{
            .clip_id = 1,
            .source_time = try editor_time.Time.zero(1000),
            .width = 1280,
            .height = 720,
        }, &effects, .{}),
    );
}

test "disabled effects preserve the identity matrix" {
    const effects = [_]effect_mod.Effect{.{
        .transform = .{
            .enabled = false,
            .translation_x = 100,
        },
    }};
    const matrix = try buildMatrix(.{
        .clip_id = 1,
        .source_time = try editor_time.Time.zero(1000),
        .width = 640,
        .height = 480,
    }, &effects, .{});
    const output = matrix.apply(.{ .x = 12, .y = 34 });
    try std.testing.expectApproxEqAbs(@as(f64, 12), output.x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 34), output.y, 0.000001);
}

test "render request preserves clip identity, source time and effect order" {
    const snapshot_mod = @import("../editor/project_snapshot.zig");
    const asset_id = @as(@import("../editor/media_asset.zig").AssetId, @enumFromInt(3));
    const effects = [_]effect_mod.Effect{
        .{ .transform = .{ .translation_x = 8 } },
        .{ .stabilization = .{} },
    };
    const asset = snapshot_mod.Asset{
        .id = asset_id,
        .path = "take.mp4",
        .duration = try editor_time.Time.init(180_000, 90_000),
        .has_audio = true,
    };
    const clip = snapshot_mod.Clip{
        .id = @enumFromInt(9),
        .asset_id = asset_id,
        .timeline_start = try editor_time.Time.zero(1_000_000),
        .timeline_duration = try editor_time.Time.init(1_000_000, 1_000_000),
        .source_in = try editor_time.Time.zero(90_000),
        .source_out = try editor_time.Time.init(90_000, 90_000),
        .effects = &effects,
    };
    const source_time = try editor_time.Time.init(45_000, 90_000);
    const request = render_plan.FrameRequest{
        .asset = &asset,
        .clip = &clip,
        .timeline_time = try editor_time.Time.init(500_000, 1_000_000),
        .source_time = source_time,
        .effects = clip.effects,
    };
    const context = contextFromRequest(request, 1920, 1080, 15);

    try std.testing.expectEqual(@as(u64, 9), context.clip_id);
    try std.testing.expectEqual(source_time, context.source_time);
    try std.testing.expectEqual(@as(?usize, 15), context.frame_index);
    try std.testing.expectEqual(@as(usize, 2), request.effects.len);
}
