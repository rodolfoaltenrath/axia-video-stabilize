const std = @import("std");
const rl = @import("raylib");
const state_mod = @import("../app_state.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");

pub const UiResult = struct {
    parameters: state_mod.Parameters,
    import_requested: bool = false,
    start_requested: bool = false,
    cancel_requested: bool = false,
};

pub fn draw(snapshot: state_mod.Snapshot) UiResult {
    const width: f32 = @floatFromInt(rl.getScreenWidth());
    const height: f32 = @floatFromInt(rl.getScreenHeight());
    const top_h: f32 = 64;
    const right_w: f32 = if (width > 900) 320 else 270;
    const timeline_h: f32 = 174;
    const pad: f32 = 16;

    rl.clearBackground(theme.background);
    const top_actions = drawTopBar(width, top_h, snapshot);

    const preview_area = rl.Rectangle{
        .x = pad,
        .y = top_h + pad,
        .width = @max(240, width - right_w - pad * 3),
        .height = @max(180, height - top_h - timeline_h - pad * 3),
    };
    drawPreview(preview_area, snapshot);

    const panel = rl.Rectangle{
        .x = width - right_w - pad,
        .y = top_h + pad,
        .width = right_w,
        .height = height - top_h - pad * 2,
    };
    var result = drawParameters(panel, snapshot);
    result.import_requested = top_actions.import_requested;
    result.start_requested = result.start_requested or top_actions.start_requested;

    const timeline = rl.Rectangle{
        .x = pad,
        .y = height - timeline_h - pad,
        .width = preview_area.width,
        .height = timeline_h,
    };
    drawTimeline(timeline, snapshot);
    return result;
}

const TopBarActions = struct {
    import_requested: bool,
    start_requested: bool,
};

fn drawTopBar(width: f32, height: f32, snapshot: state_mod.Snapshot) TopBarActions {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = width, .height = height }, theme.surface);
    rl.drawLineEx(.{ .x = 0, .y = height }, .{ .x = width, .y = height }, 1, theme.border);
    rl.drawCircleV(.{ .x = 30, .y = 32 }, 13, theme.accent);
    components.textStrong("S", 25, 21, 20, theme.text);
    components.textStrong("AXIA", 54, 19, 18, theme.text);
    components.text("WORKSPACE", 55, 40, 10, theme.text_muted);

    const busy = snapshot.phase.isBusy();
    return .{
        .import_requested = components.button(
            .{ .x = width - 306, .y = 14, .width = 132, .height = 38 },
            "IMPORTAR VÍDEO",
            .secondary,
            !busy,
        ),
        .start_requested = components.button(
            .{ .x = width - 162, .y = 14, .width = 146, .height = 38 },
            "ESTABILIZAR",
            .primary,
            snapshot.media.hasInput() and !busy,
        ),
    };
}

fn drawPreview(area: rl.Rectangle, snapshot: state_mod.Snapshot) void {
    rl.drawRectangleRounded(area, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(area, 0.025, 10, 1, theme.border);
    components.text("PREVIEW", area.x + 18, area.y + 15, 12, theme.text_muted);
    components.text("ORIGINAL  |  ESTABILIZADO", area.x + area.width - 224, area.y + 15, 12, theme.text_muted);

    const viewport = fitAspect(.{
        .x = area.x + 20,
        .y = area.y + 44,
        .width = area.width - 40,
        .height = area.height - 66,
    }, 16.0 / 9.0);
    rl.drawRectangleRec(viewport, theme.preview);

    // A quiet placeholder that already resembles the final video viewport.
    rl.drawRectangleGradientV(@intFromFloat(viewport.x), @intFromFloat(viewport.y), @intFromFloat(viewport.width), @intFromFloat(viewport.height), rl.Color.init(28, 39, 58, 255), rl.Color.init(9, 13, 21, 255));
    const horizon = viewport.y + viewport.height * 0.57;
    rl.drawCircleV(.{ .x = viewport.x + viewport.width * 0.72, .y = viewport.y + viewport.height * 0.28 }, viewport.height * 0.08, rl.Color.init(231, 172, 98, 190));
    rl.drawTriangle(.{ .x = viewport.x, .y = viewport.y + viewport.height }, .{ .x = viewport.x + viewport.width * 0.38, .y = horizon }, .{ .x = viewport.x + viewport.width * 0.62, .y = viewport.y + viewport.height }, rl.Color.init(21, 53, 55, 255));
    rl.drawTriangle(.{ .x = viewport.x + viewport.width * 0.25, .y = viewport.y + viewport.height }, .{ .x = viewport.x + viewport.width * 0.64, .y = horizon - 18 }, .{ .x = viewport.x + viewport.width, .y = viewport.y + viewport.height }, rl.Color.init(28, 68, 63, 255));

    if (snapshot.phase != .idle) drawTrackingOverlay(viewport, snapshot.progress);
    if (snapshot.media.hasInput()) {
        components.text(snapshot.media.name(), viewport.x + 18, viewport.y + viewport.height - 30, 12, rl.Color.init(210, 218, 229, 180));
    } else {
        components.text("IMPORTE UM VÍDEO PARA COMEÇAR", viewport.x + 18, viewport.y + viewport.height - 30, 12, rl.Color.init(210, 218, 229, 180));
    }
}

fn drawTrackingOverlay(viewport: rl.Rectangle, progress: f32) void {
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        var column: usize = 0;
        while (column < 7) : (column += 1) {
            const x = viewport.x + 42 + @as(f32, @floatFromInt(column)) * (viewport.width - 84) / 6.0;
            const y = viewport.y + 35 + @as(f32, @floatFromInt(row)) * (viewport.height - 70) / 3.0;
            const drift = @sin(progress * 9.0 + @as(f32, @floatFromInt(row + column))) * 5.0;
            rl.drawCircleV(.{ .x = x + drift, .y = y }, 2.5, theme.success);
            rl.drawLineEx(.{ .x = x, .y = y }, .{ .x = x + drift, .y = y - 3 }, 1, rl.Color.init(71, 205, 144, 120));
        }
    }
}

fn drawParameters(panel: rl.Rectangle, snapshot: state_mod.Snapshot) UiResult {
    var result = UiResult{ .parameters = snapshot.parameters };
    rl.drawRectangleRounded(panel, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(panel, 0.025, 10, 1, theme.border);
    const x = panel.x + 20;
    const content_w = panel.width - 40;

    components.textStrong("PARÂMETROS", x, panel.y + 18, 12, theme.text_muted);
    components.textStrong("Estabilização", x, panel.y + 47, 20, theme.text);
    rl.drawLineEx(.{ .x = x, .y = panel.y + 82 }, .{ .x = panel.x + panel.width - 20, .y = panel.y + 82 }, 1, theme.border);

    components.text("MODO", x, panel.y + 104, 12, theme.text_muted);
    const left = rl.Rectangle{ .x = x, .y = panel.y + 126, .width = content_w * 0.5 - 4, .height = 38 };
    const right = rl.Rectangle{ .x = x + content_w * 0.5 + 4, .y = left.y, .width = content_w * 0.5 - 4, .height = 38 };
    if (components.button(left, "MOVIMENTO", if (result.parameters.mode == .motion) .primary else .secondary, true)) result.parameters.mode = .motion;
    if (components.button(right, "DISTORÇÃO", if (result.parameters.mode == .distortion) .primary else .secondary, false)) result.parameters.mode = .distortion;

    _ = components.slider(.{ .x = x, .y = panel.y + 192, .width = content_w, .height = 50 }, "Suavidade", &result.parameters.smoothness, 0, 100, "%");
    _ = components.slider(.{ .x = x, .y = panel.y + 260, .width = content_w, .height = 50 }, "Margem de crop", &result.parameters.crop, 0, 30, "%");
    _ = components.toggle(x, panel.y + 332, "Crop dinâmico", &result.parameters.dynamic_crop);

    const note = rl.Rectangle{ .x = x, .y = panel.y + 372, .width = content_w, .height = 68 };
    rl.drawRectangleRounded(note, 0.12, 8, theme.surface_alt);
    components.textStrong("PIPELINE REAL EM 2 PASSOS", note.x + 12, note.y + 11, 11, theme.accent);
    if (snapshot.media.hasInput()) {
        components.text("Movimento global via libvidstab.", note.x + 12, note.y + 31, 12, theme.text_muted);
        components.text("Saída MP4 ao lado do original.", note.x + 12, note.y + 47, 12, theme.text_muted);
    } else {
        components.text("Clique em Importar vídeo.", note.x + 12, note.y + 31, 12, theme.text_muted);
        components.text("MP4, MOV, MKV, AVI, WebM, MTS.", note.x + 12, note.y + 47, 12, theme.text_muted);
    }

    const busy = snapshot.phase.isBusy();
    const button_y = panel.y + panel.height - 58;
    if (busy) {
        result.cancel_requested = components.button(.{ .x = x, .y = button_y, .width = content_w, .height = 40 }, "CANCELAR PROCESSAMENTO", .danger, true);
    } else {
        result.start_requested = components.button(
            .{ .x = x, .y = button_y, .width = content_w, .height = 40 },
            "ANALISAR E EXPORTAR",
            .primary,
            snapshot.media.hasInput(),
        );
    }
    return result;
}

fn drawTimeline(area: rl.Rectangle, snapshot: state_mod.Snapshot) void {
    rl.drawRectangleRounded(area, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(area, 0.025, 10, 1, theme.border);
    components.text("TIMELINE", area.x + 18, area.y + 14, 12, theme.text_muted);
    var frame_buffer: [48]u8 = undefined;
    const frame_text = if (snapshot.total_frames) |total|
        if (snapshot.processing_speed > 0)
            std.fmt.bufPrintZ(
                &frame_buffer,
                "FRAME {d} / {d}  {d:.1}x",
                .{ snapshot.processed_frame, total, snapshot.processing_speed },
            ) catch "FRAME --"
        else
            std.fmt.bufPrintZ(&frame_buffer, "FRAME {d} / {d}", .{ snapshot.processed_frame, total }) catch "FRAME --"
    else
        "00:00:00:00";
    const frame_measure = @as(f32, @floatFromInt(frame_text.len)) * 7.0;
    components.text(frame_text, area.x + area.width - frame_measure - 18, area.y + 14, 12, theme.text);

    const track = rl.Rectangle{ .x = area.x + 18, .y = area.y + 43, .width = area.width - 36, .height = 72 };
    rl.drawRectangleRounded(track, 0.06, 8, theme.surface_alt);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const cell_w = track.width / 12.0;
        const cell = rl.Rectangle{ .x = track.x + @as(f32, @floatFromInt(i)) * cell_w + 2, .y = track.y + 3, .width = cell_w - 4, .height = track.height - 6 };
        const tint: u8 = @intCast(28 + (i % 4) * 7);
        rl.drawRectangleRounded(cell, 0.08, 4, rl.Color.init(tint, tint + 10, tint + 18, 255));
        rl.drawLineEx(.{ .x = cell.x + 4, .y = cell.y + cell.height - 10 }, .{ .x = cell.x + cell.width - 4, .y = cell.y + 15 + @as(f32, @floatFromInt(i % 3)) * 5 }, 1, theme.accent_soft);
    }
    const playhead_x = track.x + track.width * snapshot.progress;
    rl.drawLineEx(.{ .x = playhead_x, .y = track.y - 5 }, .{ .x = playhead_x, .y = track.y + track.height + 5 }, 2, theme.accent);

    components.progressBar(.{ .x = area.x + 18, .y = area.y + 134, .width = area.width - 142, .height = 8 }, snapshot.progress);
    components.text(snapshot.status(), area.x + 18, area.y + 149, 12, if (snapshot.phase == .failed) theme.danger else theme.text_muted);
    var buffer: [16]u8 = undefined;
    const percent = std.fmt.bufPrintZ(&buffer, "{d:.0}%", .{snapshot.progress * 100.0}) catch "--";
    components.text(percent, area.x + area.width - 58, area.y + 130, 14, theme.text);
}

fn fitAspect(container: rl.Rectangle, aspect: f32) rl.Rectangle {
    var width = container.width;
    var height = width / aspect;
    if (height > container.height) {
        height = container.height;
        width = height * aspect;
    }
    return .{
        .x = container.x + (container.width - width) / 2.0,
        .y = container.y + (container.height - height) / 2.0,
        .width = width,
        .height = height,
    };
}
