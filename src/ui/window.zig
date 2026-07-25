const std = @import("std");
const rl = @import("raylib");
const state_mod = @import("../app_state.zig");
const components = @import("components.zig");
const preview_player = @import("preview_player.zig");
const theme = @import("theme.zig");
const fonts = @import("fonts.zig");

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
    const player_actions = drawPreview(preview_area, snapshot, preview);

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
    drawTimeline(timeline, snapshot, preview);
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
            .{ .x = width - 152, .y = 14, .width = 132, .height = 38 },
            "IMPORTAR VÍDEO",
            .secondary,
            !busy,
        ),
        .start_requested = false, // O botão superior de estabilizar foi removido para focar a ação no painel lateral
    };
}

fn drawPreview(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) PlayerActions {
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
        .height = area.height - 112,
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
        const name = snapshot.media.name();
        const text_size = fonts.measure(name, 12, .regular);
        const pill = rl.Rectangle{
            .x = viewport.x + 10,
            .y = viewport.y + viewport.height - 34,
            .width = text_size.x + 16,
            .height = 24,
        };
        rl.drawRectangleRounded(pill, 0.5, 8, rl.Color.init(0, 0, 0, 160));
        components.text(name, pill.x + 8, pill.y + 6, 12, rl.Color.init(231, 235, 242, 255));
    } else {
        const msg = "IMPORTE UM VÍDEO PARA COMEÇAR";
        const text_size = fonts.measure(msg, 12, .regular);
        const pill = rl.Rectangle{
            .x = viewport.x + 10,
            .y = viewport.y + viewport.height - 34,
            .width = text_size.x + 16,
            .height = 24,
        };
        rl.drawRectangleRounded(pill, 0.5, 8, rl.Color.init(0, 0, 0, 160));
        components.text(msg, pill.x + 8, pill.y + 6, 12, rl.Color.init(231, 235, 242, 255));
    }
    
    if (preview.failed) {
        components.text("PREVIEW INDISPONÍVEL", viewport.x + 18, viewport.y + 18, 12, theme.danger);
    }
    
    const controls_width = @min(area.width - 40, @max(viewport.width, 460));
    return drawPreviewControls(.{
        .x = area.x + (area.width - controls_width) * 0.5,
        .y = area.y + area.height - 58,
        .width = controls_width,
        .height = 42,
    }, snapshot, preview);
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
        components.text("Movimento estimado pela engine Zig.", note.x + 12, note.y + 31, 12, theme.text_muted);
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

const PlayerButtonIcon = enum {
    backward,
    play,
    pause,
    forward,
};

fn drawPreviewControls(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) PlayerActions {
    var actions = PlayerActions{};
    const enabled = preview.loaded and !preview.failed and !snapshot.phase.isBusy();
    const progress = preview.progress();
    const seek_track = rl.Rectangle{
        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = 4,
    };
    rl.drawRectangleRounded(seek_track, 1.0, 6, theme.border);
    if (progress > 0) {
        rl.drawRectangleRounded(.{
            .x = seek_track.x,
            .y = seek_track.y,
            .width = @max(4, seek_track.width * progress),
            .height = seek_track.height,
        }, 1.0, 6, theme.accent);
    }
    rl.drawCircleV(.{
        .x = seek_track.x + seek_track.width * progress,
        .y = seek_track.y + seek_track.height * 0.5,
    }, 4, if (enabled) theme.text else theme.text_muted);

    const mouse = rl.getMousePosition();
    const seek_hitbox = rl.Rectangle{
        .x = seek_track.x,
        .y = seek_track.y - 5,
        .width = seek_track.width,
        .height = 14,
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

    const button_y = area.y + 13;
    if (playerButton(.{ .x = area.x, .y = button_y, .width = 30, .height = 25 }, .backward, enabled) and
        preview.duration_seconds > 0)
    {
        actions.seek_ratio = @floatCast(std.math.clamp(
            (preview.position_seconds - 5.0) / preview.duration_seconds,
            0.0,
            1.0,
        ));
    }
    actions.toggle_requested = playerButton(
        .{ .x = area.x + 36, .y = button_y, .width = 34, .height = 25 },
        if (preview.playing) .pause else .play,
        enabled,
    );
    if (playerButton(.{ .x = area.x + 76, .y = button_y, .width = 30, .height = 25 }, .forward, enabled) and
        preview.duration_seconds > 0)
    {
        actions.seek_ratio = @floatCast(std.math.clamp(
            (preview.position_seconds + 5.0) / preview.duration_seconds,
            0.0,
            1.0,
        ));
    }
    if (enabled and rl.isKeyPressed(.space)) actions.toggle_requested = true;

    const status: [:0]const u8 = if (preview.failed)
        "Preview indisponível"
    else if (!preview.loaded)
        "Importe um vídeo"
    else if (!preview.ready)
        "Carregando..."
    else if (preview.playing)
        "Reproduzindo"
    else
        "Pausado";
    components.text(status, area.x + 120, button_y + 6, 11, if (preview.failed) theme.danger else theme.text_muted);

    var time_buffer: [40]u8 = undefined;
    const time_text = formatPlayerTime(&time_buffer, preview.position_seconds, preview.duration_seconds);
    const time_measure = @as(f32, @floatFromInt(time_text.len)) * 6.6;
    components.text(
        time_text,
        area.x + area.width - time_measure,
        button_y + 6,
        11,
        theme.text,
    );
    return actions;
}

fn playerButton(rect: rl.Rectangle, icon: PlayerButtonIcon, enabled: bool) bool {
    const mouse = rl.getMousePosition();
    const hovered = enabled and rl.checkCollisionPointRec(mouse, rect);
    rl.drawRectangleRounded(rect, 0.18, 6, if (hovered) theme.surface_hover else theme.surface_alt);
    rl.drawRectangleRoundedLinesEx(rect, 0.18, 6, 1, theme.border);
    const color = if (enabled) theme.text else theme.text_muted;
    const center = rl.Vector2{
        .x = rect.x + rect.width * 0.5,
        .y = rect.y + rect.height * 0.5,
    };
    switch (icon) {
        .backward => components.textStrong("-5", center.x - 7, center.y - 6, 11, color),
        .forward => components.textStrong("+5", center.x - 7, center.y - 6, 11, color),
        .play => rl.drawTriangle(
            .{ .x = center.x - 4, .y = center.y - 6 },
            .{ .x = center.x - 4, .y = center.y + 6 },
            .{ .x = center.x + 6, .y = center.y },
            color,
        ),
        .pause => {
            rl.drawRectangleRec(.{ .x = center.x - 5, .y = center.y - 6, .width = 3, .height = 12 }, color);
            rl.drawRectangleRec(.{ .x = center.x + 2, .y = center.y - 6, .width = 3, .height = 12 }, color);
        },
    }
    return hovered and rl.isMouseButtonPressed(.left);
}

fn drawTimeline(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) void {
    rl.drawRectangleRounded(area, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(area, 0.025, 10, 1, theme.border);
    components.text("TIMELINE", area.x + 18, area.y + 14, 12, theme.text_muted);

    var time_buffer: [40]u8 = undefined;
    const time_text = formatPlayerTime(&time_buffer, preview.position_seconds, preview.duration_seconds);
    const time_measure = @as(f32, @floatFromInt(time_text.len)) * 7.2;
    components.text(time_text, area.x + area.width - time_measure - 18, area.y + 14, 12, theme.text);

    const track = rl.Rectangle{
        .x = area.x + 18,
        .y = area.y + 51,
        .width = area.width - 36,
        .height = 70,
    };
    rl.drawRectangleRounded(track, 0.06, 8, theme.surface_alt);

    var tick: usize = 0;
    while (tick <= 10) : (tick += 1) {
        const x = track.x + track.width * @as(f32, @floatFromInt(tick)) / 10.0;
        const tick_height: f32 = if (tick % 5 == 0) 2 else 5;
        rl.drawLineEx(
            .{ .x = x, .y = track.y - 10 },
            .{ .x = x, .y = track.y - tick_height },
            1,
            rl.Color.init(80, 90, 110, 255), // Nova cor sutil para os divisores
        );
    }

    if (snapshot.media.hasInput()) {
        const clip = rl.Rectangle{
            .x = track.x + 4,
            .y = track.y + 8,
            .width = track.width - 8,
            .height = track.height - 16,
        };
        rl.drawRectangleRounded(clip, 0.08, 6, theme.accent_soft);
        
        // Efeito de inner glow (vidro) no clipe
        const inner_clip = rl.Rectangle{
            .x = clip.x + 1,
            .y = clip.y + 1,
            .width = clip.width - 2,
            .height = clip.height - 2,
        };
        rl.drawRectangleRoundedLinesEx(inner_clip, 0.08, 6, 1, rl.Color.init(255, 255, 255, 25));
        rl.drawRectangleRoundedLinesEx(clip, 0.08, 6, 1, theme.accent);
        
        components.textStrong(snapshot.media.name(), clip.x + 12, clip.y + 18, 12, theme.text);

        // Renderiza o tempo total dentro do próprio bloco do clipe se ele não for muito esmagado
        if (clip.width > 150) {
            const dur_total: u64 = @intFromFloat(@max(0.0, @floor(preview.duration_seconds)));
            var dur_buf: [16]u8 = undefined;
            const dur_text = std.fmt.bufPrintZ(
                &dur_buf,
                "{d:0>2}:{d:0>2}",
                .{ dur_total / 60, dur_total % 60 },
            ) catch "00:00";
            
            const dur_size = fonts.measure(dur_text, 11, .regular);
            components.text(dur_text, clip.x + clip.width - dur_size.x - 12, clip.y + 19, 11, theme.accent);
        }

        const playhead_x = track.x + track.width * preview.progress();
        rl.drawLineEx(
            .{ .x = playhead_x, .y = track.y - 5 },
            .{ .x = playhead_x, .y = track.y + track.height + 5 },
            2,
            theme.accent,
        );
        rl.drawTriangle(
            .{ .x = playhead_x - 5, .y = track.y - 6 },
            .{ .x = playhead_x + 5, .y = track.y - 6 },
            .{ .x = playhead_x, .y = track.y },
            theme.accent,
        );
    } else {
        components.text("NENHUMA MÍDIA NA TIMELINE", track.x + 14, track.y + 26, 12, theme.text_muted);
    }

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
        components.text(
            if (snapshot.media.hasInput()) "1 faixa de vídeo" else "Importe uma mídia para começar.",
            area.x + 18,
            area.y + 143,
            12,
            theme.text_muted,
        );
    }
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