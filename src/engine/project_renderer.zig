const std = @import("std");
const render_plan = @import("../editor/render_plan.zig");
const decoder_mod = @import("decoder.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const project_decoder = @import("project_decoder.zig");
const types = @import("types.zig");

pub const Error = error{
    InvalidPixelFormat,
    SizeOverflow,
} || project_decoder.Error || frame_pipeline.Error || std.mem.Allocator.Error;

pub const RenderedFrame = struct {
    request: render_plan.FrameRequest,
    timing: types.FrameTiming,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
};

/// Shared native frame entry point for editor preview and project export.
/// Output pixels are borrowed and remain valid until the next render or
/// `deinit`.
pub const ProjectRenderer = struct {
    allocator: std.mem.Allocator,
    decoder: project_decoder.ProjectDecoder,
    output_pixels: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        decoder_options: decoder_mod.Options,
    ) Error!ProjectRenderer {
        switch (decoder_options.output_format) {
            .bgra8_analysis, .bgra8 => {},
            .gray8 => return error.InvalidPixelFormat,
        }
        return .{
            .allocator = allocator,
            .decoder = project_decoder.ProjectDecoder.init(
                allocator,
                decoder_options,
            ),
        };
    }

    pub fn deinit(self: *ProjectRenderer) void {
        self.decoder.deinit();
        if (self.output_pixels) |pixels| self.allocator.free(pixels);
        self.* = undefined;
    }

    pub fn render(
        self: *ProjectRenderer,
        request: render_plan.FrameRequest,
        prepared: frame_pipeline.PreparedEffects,
    ) Error!RenderedFrame {
        const decoded = try self.decoder.read(request);
        const stride = std.math.mul(
            usize,
            @as(usize, decoded.frame.width),
            decoder_mod.PixelFormat.bgra8.bytesPerPixel(),
        ) catch return error.SizeOverflow;
        const required_size = std.math.mul(
            usize,
            stride,
            @as(usize, decoded.frame.height),
        ) catch return error.SizeOverflow;
        try self.ensureOutputSize(required_size);

        try frame_pipeline.processRequestBgra(
            decoded.frame.pixels,
            decoded.frame.stride,
            self.output_pixels.?,
            stride,
            decoded.request,
            decoded.frame.width,
            decoded.frame.height,
            null,
            prepared,
        );
        return .{
            .request = decoded.request,
            .timing = decoded.frame.timing,
            .pixels = self.output_pixels.?,
            .width = decoded.frame.width,
            .height = decoded.frame.height,
            .stride = stride,
        };
    }

    fn ensureOutputSize(self: *ProjectRenderer, required_size: usize) !void {
        if (self.output_pixels) |pixels| {
            if (pixels.len == required_size) return;
            self.output_pixels = try self.allocator.realloc(pixels, required_size);
        } else {
            self.output_pixels = try self.allocator.alloc(u8, required_size);
        }
    }
};

test "project renderer rejects non-color decoder output" {
    try std.testing.expectError(
        error.InvalidPixelFormat,
        ProjectRenderer.init(std.testing.allocator, .{ .output_format = .gray8 }),
    );
}

test "disabled project renderer reports unavailable native backend" {
    if (decoder_mod.native_enabled) return error.SkipZigTest;
    const snapshot_mod = @import("../editor/project_snapshot.zig");
    const editor_time = @import("../editor/time.zig");
    const effects = [_]@import("../effects/effect.zig").Effect{};
    const asset = snapshot_mod.Asset{
        .id = @enumFromInt(1),
        .path = "take.mp4",
        .duration = try editor_time.Time.init(90_000, 90_000),
        .has_audio = false,
    };
    const clip = snapshot_mod.Clip{
        .id = @enumFromInt(1),
        .asset_id = asset.id,
        .timeline_start = try editor_time.Time.zero(1_000_000),
        .timeline_duration = try editor_time.Time.init(1_000_000, 1_000_000),
        .source_in = try editor_time.Time.zero(90_000),
        .source_out = asset.duration,
        .effects = &effects,
    };
    const request = render_plan.FrameRequest{
        .asset = &asset,
        .clip = &clip,
        .timeline_time = clip.timeline_start,
        .source_time = clip.source_in,
        .effects = clip.effects,
    };
    var renderer = try ProjectRenderer.init(
        std.testing.allocator,
        .{ .output_format = .bgra8 },
    );
    defer renderer.deinit();
    try std.testing.expectError(
        error.BackendNotEnabled,
        renderer.render(request, .{}),
    );
}
