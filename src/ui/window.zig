const std = @import("std");
const rl = @import("raylib");
const state_mod = @import("../app_state.zig");
const components = @import("components.zig");
const preview_player = @import("preview_player.zig");
const theme = @import("theme.zig");

pub const UiResult = struct {
    parameters: state_mod.Parameters,
    import_requested: bool = false,
    preview_toggle_requested: bool = false,
    preview_seek_ratio: ?f32 = null,
    start_requested: bool = false,
    cancel_requested: bool = false,
};

pub fn draw(snapshot: state_mod.Snapshot, preview: preview_player.View) UiResult {
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
    drawPreview(preview_area, snapshot, preview);

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
    const player_actions = drawTimeline(timeline, snapshot, preview);
    result.preview_toggle_requested = player_actions.toggle_requested;
    result.preview_seek_ratio = player_actions.seek_ratio;
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

fn drawPreview(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) void {
    rl.drawRectangleRounded(area, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(area, 0.025, 10, 1, theme.border);
    components.text("PREVIEW", area.x + 18, area.y + 15, 12, theme.text_muted);
    components.text("ORIGINAL", area.x + area.width - 78, area.y + 15, 12, theme.text_muted);

    const aspect = if (preview.width > 0 and preview.height > 0)
        @as(f32, @floatFromInt(preview.width)) / @as(f32, @floatFromInt(preview.height))
    else
        16.0 / 9.0;
    const viewport = fitAspect(.{
        .x = area.x + 20,
        .y = area.y + 44,
        .width = area.width - 40,
        .height = area.height - 66,
    }, aspect);
    rl.drawRectangleRec(viewport, theme.preview);

    if (preview.texture) |texture| {
        rl.drawTexturePro(
            texture,
            .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(preview.width),
                .height = @floatFromInt(preview.height),
            },
            viewport,
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
    }

    if (snapshot.media.hasInput()) {
        components.text(snapshot.media.name(), viewport.x + 18, viewport.y + viewport.height - 30, 12, rl.Color.init(210, 218, 229, 180));
    } else {
        components.text("IMPORTE UM VÍDEO PARA COMEÇAR", viewport.x + 18, viewport.y + viewport.height - 30, 12, rl.Color.init(210, 218, 229, 180));
    }
    if (preview.failed) {
        components.text("PREVIEW INDISPONÍVEL", viewport.x + 18, viewport.y + 18, 12, theme.danger);
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

const PlayerActions = struct {
    toggle_requested: bool = false,
    seek_ratio: ?f32 = null,
};

fn drawTimeline(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) PlayerActions {
    var actions = PlayerActions{};
    rl.drawRectangleRounded(area, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(area, 0.025, 10, 1, theme.border);
    components.text("PLAYER", area.x + 18, area.y + 14, 12, theme.text_muted);

    var time_buffer: [40]u8 = undefined;
    const time_text = formatPlayerTime(
        &time_buffer,
        preview.position_seconds,
        preview.duration_seconds,
    );
    const time_measure = @as(f32, @floatFromInt(time_text.len)) * 7.2;
    components.text(time_text, area.x + area.width - time_measure - 18, area.y + 14, 12, theme.text);

    const enabled = preview.loaded and !preview.failed and !snapshot.phase.isBusy();
    const seek_track = rl.Rectangle{
        .x = area.x + 18,
        .y = area.y + 52,
        .width = area.width - 36,
        .height = 10,
    };
    rl.drawRectangleRounded(seek_track, 1.0, 8, theme.border);
    const preview_progress = preview.progress();
    if (preview_progress > 0) {
        rl.drawRectangleRounded(.{
            .x = seek_track.x,
            .y = seek_track.y,
            .width = @max(8, seek_track.width * preview_progress),
            .height = seek_track.height,
        }, 1.0, 8, theme.accent);
    }
    rl.drawCircleV(.{
        .x = seek_track.x + seek_track.width * preview_progress,
        .y = seek_track.y + seek_track.height * 0.5,
    }, 6, if (enabled) theme.text else theme.text_muted);

    const mouse = rl.getMousePosition();
    const seek_hitbox = rl.Rectangle{
        .x = seek_track.x,
        .y = seek_track.y - 8,
        .width = seek_track.width,
        .height = seek_track.height + 16,
    };
    if (enabled and
        rl.checkCollisionPointRec(mouse, seek_hitbox) and
        rl.isMouseButtonPressed(.left))
    {
        actions.seek_ratio = std.math.clamp(
            (mouse.x - seek_track.x) / seek_track.width,
            0.0,
            1.0,
        );
    }

    actions.toggle_requested = components.button(
        .{ .x = area.x + 18, .y = area.y + 82, .width = 110, .height = 38 },
        if (preview.playing) "PAUSAR" else "REPRODUZIR",
        .secondary,
        enabled,
    );
    if (enabled and rl.isKeyPressed(.space)) actions.toggle_requested = true;
    components.text(
        "Espaço: reproduzir/pausar",
        area.x + 146,
        area.y + 94,
        12,
        theme.text_muted,
    );

    if (snapshot.phase.isBusy()) {
        components.progressBar(.{
            .x = area.x + 18,
            .y = area.y + 138,
            .width = area.width - 90,
            .height = 8,
        }, snapshot.progress);
        var percent_buffer: [16]u8 = undefined;
        const percent = std.fmt.bufPrintZ(
            &percent_buffer,
            "{d:.0}%",
            .{snapshot.progress * 100.0},
        ) catch "--";
        components.text(percent, area.x + area.width - 58, area.y + 133, 14, theme.text);
        components.text(snapshot.status(), area.x + 18, area.y + 153, 12, theme.text_muted);
    } else {
        const status: [:0]const u8 = if (preview.failed)
            "Falha ao decodificar o preview."
        else if (!preview.loaded)
            "Importe um vídeo para visualizar."
        else if (!preview.ready)
            "Preparando o primeiro quadro..."
        else if (preview.playing)
            "Reproduzindo preview otimizado."
        else
            "Preview pausado.";
        components.text(status, area.x + 18, area.y + 143, 12, if (preview.failed) theme.danger else theme.text_muted);
    }
    return actions;
}

fn formatPlayerTime(buffer: *[40]u8, position: f64, duration: f64) [:0]const u8 {
    const position_total: u64 = @intFromFloat(@max(0.0, @floor(position)));
    const duration_total: u64 = @intFromFloat(@max(0.0, @floor(duration)));
    return std.fmt.bufPrintZ(
        buffer,
        "{d:0>2}:{d:0>2} / {d:0>2}:{d:0>2}",
        .{
            position_total / 60,
            position_total % 60,
            duration_total / 60,
            duration_total % 60,
        },
    ) catch "00:00 / 00:00";
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
