const std = @import("std");
const sync = @import("../utils/sync.zig");
const rl = @import("raylib");
const build_options = @import("build_options");
const state_mod = @import("../app_state.zig");
const components = @import("components.zig");
const preview_player = @import("preview_player.zig");
const preview_thumbnails = @import("preview_thumbnails.zig");
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
    const left_w: f32 = if (width >= 1200) 228 else 190;
    const right_w: f32 = if (width >= 1200) 316 else 280;
    const timeline_h: f32 = 196;
    const pad: f32 = 12;

    rl.clearBackground(theme.background);
    const top_actions = drawTopBar(width, top_h, snapshot);

    const library = rl.Rectangle{
        .x = pad,
        .y = top_h + pad,
        .width = left_w,
        .height = @max(180, height - top_h - timeline_h - pad * 3),
    };
    const library_import_requested = drawMediaLibrary(library, snapshot);

    const preview_area = rl.Rectangle{
        .x = library.x + library.width + pad,
        .y = top_h + pad,
        .width = @max(240, width - left_w - right_w - pad * 4),
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
    result.import_requested = top_actions.import_requested or
        library_import_requested or player_actions.import_requested;
    result.start_requested = result.start_requested or top_actions.start_requested;

    const timeline = rl.Rectangle{
        .x = pad,
        .y = height - timeline_h - pad,
        .width = width - right_w - pad * 3,
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
    rl.drawRectangleRec(.{ .x = 0, .y = height - 1, .width = width, .height = 1 }, theme.border_soft);
    rl.drawRectangleRec(.{ .x = 0, .y = height, .width = width, .height = 4 }, theme.shadow);

    const mark = rl.Rectangle{ .x = 16, .y = 12, .width = 40, .height = 40 };
    rl.drawRectangleRounded(mark, 0.28, 8, theme.accent);
    components.textStrong("A", mark.x + 11, mark.y + 7, 21, theme.text);
    components.textStrong("AXIA", 68, 12, 18, theme.text);
    var version_buffer: [32]u8 = undefined;
    const version_label = std.fmt.bufPrintZ(
        &version_buffer,
        "v{s}",
        .{build_options.version},
    ) catch "versão inválida";
    components.text(version_label, 122, 16, 9, theme.text_subtle);
    components.text("EDITOR DE VÍDEO", 68, 36, 10, theme.text_muted);

    const workspace = rl.Rectangle{ .x = width * 0.5 - 45, .y = 15, .width = 90, .height = 34 };
    rl.drawRectangleRounded(workspace, 0.2, 8, theme.accent_subtle);
    rl.drawRectangleRoundedLinesEx(workspace, 0.2, 8, 1, theme.accent_soft);
    components.textStrong("EDITAR", workspace.x + 25, workspace.y + 11, 11, theme.accent_hover);

    const busy = snapshot.phase.isBusy();
    const import_rect = rl.Rectangle{
        .x = width - 162,
        .y = 12,
        .width = 146,
        .height = 40,
    };
    drawPhasePill(import_rect.x - 14, height * 0.5, snapshot.phase);
    return .{
        .import_requested = components.button(
            import_rect,
            "+  MÍDIA",
            .secondary,
            !busy,
        ),
        .start_requested = false,
    };
}

fn drawMediaLibrary(area: rl.Rectangle, snapshot: state_mod.Snapshot) bool {
    components.card(area);
    components.textStrong("Mídia", area.x + 16, area.y + 15, 15, theme.text);
    components.text(
        if (snapshot.media.hasInput()) "1 item no projeto" else "Projeto vazio",
        area.x + 16,
        area.y + 38,
        10,
        theme.text_subtle,
    );

    const add_rect = rl.Rectangle{
        .x = area.x + area.width - 44,
        .y = area.y + 12,
        .width = 30,
        .height = 28,
    };
    const add_requested = components.button(
        add_rect,
        "+",
        .secondary,
        !snapshot.phase.isBusy(),
    );
    rl.drawLineEx(
        .{ .x = area.x + 14, .y = area.y + 62 },
        .{ .x = area.x + area.width - 14, .y = area.y + 62 },
        1,
        theme.border_soft,
    );

    if (!snapshot.media.hasInput()) {
        const empty = rl.Rectangle{
            .x = area.x + 12,
            .y = area.y + 76,
            .width = area.width - 24,
            .height = 112,
        };
        const hovered = !snapshot.phase.isBusy() and
            rl.checkCollisionPointRec(rl.getMousePosition(), empty);
        rl.drawRectangleRounded(
            empty,
            0.08,
            8,
            if (hovered) theme.surface_hover else theme.surface_raised,
        );
        rl.drawRectangleRoundedLinesEx(empty, 0.08, 8, 1, theme.border_soft);
        const center_x = empty.x + empty.width * 0.5;
        drawMediaIcon(.{
            .x = center_x - 15,
            .y = empty.y + 18,
            .width = 30,
            .height = 24,
        }, theme.text_muted);
        const label = "Importar mídia";
        const label_size = fonts.measure(label, 11, .semibold);
        components.textStrong(
            label,
            center_x - label_size.x * 0.5,
            empty.y + 58,
            11,
            theme.text,
        );
        const hint = "ou arraste um vídeo";
        const hint_size = fonts.measure(hint, 9, .regular);
        components.text(
            hint,
            center_x - hint_size.x * 0.5,
            empty.y + 79,
            9,
            theme.text_muted,
        );
        return add_requested or (hovered and rl.isMouseButtonPressed(.left));
    }

    const item = rl.Rectangle{
        .x = area.x + 10,
        .y = area.y + 74,
        .width = area.width - 20,
        .height = 78,
    };
    rl.drawRectangleRounded(item, 0.07, 8, theme.accent_subtle);
    rl.drawRectangleRoundedLinesEx(item, 0.07, 8, 1, theme.accent);
    const thumbnail = rl.Rectangle{
        .x = item.x + 8,
        .y = item.y + 9,
        .width = 62,
        .height = 60,
    };
    rl.drawRectangleRounded(thumbnail, 0.08, 6, theme.preview);
    drawMediaIcon(.{
        .x = thumbnail.x + 18,
        .y = thumbnail.y + 19,
        .width = 26,
        .height = 22,
    }, theme.accent_hover);
    drawClippedText(
        snapshot.media.name(),
        thumbnail.x + thumbnail.width + 9,
        item.y + 14,
        item.width - thumbnail.width - 27,
        11,
        theme.text,
    );
    components.text(
        "VÍDEO  |  1 CLIPE",
        thumbnail.x + thumbnail.width + 9,
        item.y + 38,
        8,
        theme.text_subtle,
    );
    components.textStrong(
        "SELECIONADO",
        thumbnail.x + thumbnail.width + 9,
        item.y + 56,
        8,
        theme.accent_hover,
    );
    return add_requested;
}

fn drawMediaIcon(rect: rl.Rectangle, color: rl.Color) void {
    rl.drawRectangleRounded(rect, 0.14, 6, theme.surface_alt);
    rl.drawRectangleRoundedLinesEx(rect, 0.14, 6, 1, color);
    rl.drawTriangle(
        .{ .x = rect.x + rect.width * 0.43, .y = rect.y + rect.height * 0.27 },
        .{ .x = rect.x + rect.width * 0.43, .y = rect.y + rect.height * 0.73 },
        .{ .x = rect.x + rect.width * 0.7, .y = rect.y + rect.height * 0.5 },
        color,
    );
}

fn drawPhasePill(right: f32, center_y: f32, phase: state_mod.Phase) void {
    const label = phase.label();
    const label_size = fonts.measure(label, 11, .semibold);
    const width = label_size.x + 38;
    const rect = rl.Rectangle{
        .x = right - width,
        .y = center_y - 15,
        .width = width,
        .height = 30,
    };
    const color = phaseColor(phase);
    rl.drawRectangleRounded(rect, 0.5, 8, theme.surface_alt);
    rl.drawRectangleRoundedLinesEx(rect, 0.5, 8, 1, theme.border_soft);
    rl.drawCircleV(.{ .x = rect.x + 14, .y = center_y }, 4, color);
    components.textStrong(label, rect.x + 25, rect.y + 9, 11, theme.text_muted);
}

fn phaseColor(phase: state_mod.Phase) rl.Color {
    return switch (phase) {
        .completed => theme.success,
        .failed => theme.danger,
        .cancelled => theme.text_subtle,
        .loading, .analyzing, .smoothing, .rendering, .muxing => theme.accent,
        .idle => theme.success,
    };
}

fn drawPreview(
    area: rl.Rectangle,
    snapshot: state_mod.Snapshot,
    preview: preview_player.View,
) PlayerActions {
    components.card(area);
    components.textStrong("Monitor", area.x + 18, area.y + 15, 14, theme.text);

    var source_buffer: [48]u8 = undefined;
    const source_label: [:0]const u8 = if (preview.width > 0 and preview.height > 0)
        std.fmt.bufPrintZ(
            &source_buffer,
            "{d}x{d}  {s}",
            .{
                preview.width,
                preview.height,
                if (preview.using_proxy) "PROXY" else "PREVIEW",
            },
        ) catch "PREVIEW"
    else
        "PREVIEW";
    const source_size = fonts.measure(source_label, 10, .semibold);
    const source_pill = rl.Rectangle{
        .x = area.x + area.width - source_size.x - 34,
        .y = area.y + 12,
        .width = source_size.x + 18,
        .height = 24,
    };
    rl.drawRectangleRounded(source_pill, 0.5, 8, theme.accent_subtle);
    components.textStrong(source_label, source_pill.x + 9, source_pill.y + 7, 10, theme.accent_hover);

    const aspect = if (preview.width > 0 and preview.height > 0)
        @as(f32, @floatFromInt(preview.width)) / @as(f32, @floatFromInt(preview.height))
    else
        16.0 / 9.0;
    const viewport = fitAspect(.{
        .x = area.x + 18,
        .y = area.y + 48,
        .width = area.width - 36,
        .height = area.height - 116,
    }, aspect);
    rl.drawRectangleRounded(viewport, 0.018, 8, theme.preview);
    rl.drawRectangleRoundedLinesEx(viewport, 0.018, 8, 1, theme.border_soft);

    var draw_texture_ms: f64 = 0;
    const scrub_thumbnail_available = preview.seeking and
        preview.thumbnail_texture != null and
        preview.thumbnail_count > 0 and
        preview.thumbnail_cell_width > 0 and
        preview.thumbnail_cell_height > 0;
    if (scrub_thumbnail_available) {
        const draw_started = sync.nanoTimestamp();
        const thumbnail_index = preview_thumbnails.indexForProgress(preview.progress());
        rl.drawTexturePro(
            preview.thumbnail_texture.?,
            .{
                .x = @as(f32, @floatFromInt(
                    thumbnail_index * preview.thumbnail_cell_width,
                )),
                .y = 0,
                .width = @floatFromInt(preview.thumbnail_cell_width),
                .height = @floatFromInt(preview.thumbnail_cell_height),
            },
            viewport,
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
        const draw_elapsed = sync.nanoTimestamp() - draw_started;
        draw_texture_ms = @as(f64, @floatFromInt(@max(0, draw_elapsed))) /
            @as(f64, sync.ns_per_ms);
        components.textStrong(
            "APROXIMAÇÃO",
            viewport.x + viewport.width - 94,
            viewport.y + 18,
            9,
            theme.text_muted,
        );
    } else if (preview.texture) |texture| {
        const draw_started = sync.nanoTimestamp();
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
        const draw_elapsed = sync.nanoTimestamp() - draw_started;
        draw_texture_ms = @as(f64, @floatFromInt(@max(0, draw_elapsed))) /
            @as(f64, sync.ns_per_ms);
    }

    var empty_import_requested = false;
    if (!snapshot.media.hasInput()) {
        empty_import_requested = drawEmptyPreview(viewport);
    } else {
        const name = snapshot.media.name();
        const text_size = fonts.measure(name, 12, .regular);
        const pill = rl.Rectangle{
            .x = viewport.x + 10,
            .y = viewport.y + viewport.height - 34,
            .width = @min(text_size.x + 16, viewport.width - 20),
            .height = 24,
        };
        rl.drawRectangleRounded(pill, 0.5, 8, rl.Color.init(0, 0, 0, 160));
        drawClippedText(name, pill.x + 8, pill.y + 6, pill.width - 16, 12, theme.text);
    }

    if (preview.failed) {
        components.text("PREVIEW INDISPONÍVEL", viewport.x + 18, viewport.y + 18, 12, theme.danger);
    }
    if (preview.diagnostics_enabled and preview.loaded) {
        drawPreviewDiagnostics(viewport, preview, draw_texture_ms);
    }
    rl.drawRectangleRoundedLinesEx(viewport, 0.018, 8, 1, theme.border_soft);

    const controls_width = @min(area.width - 40, @max(viewport.width, 460));
    var actions = drawPreviewControls(.{
        .x = area.x + (area.width - controls_width) * 0.5,
        .y = area.y + area.height - 58,
        .width = controls_width,
        .height = 42,
    }, snapshot, preview);
    actions.import_requested = empty_import_requested;
    return actions;
}

fn drawPreviewDiagnostics(
    viewport: rl.Rectangle,
    preview: preview_player.View,
    draw_texture_ms: f64,
) void {
    const pipeline_fps = if (preview.decode_pipeline_ms > 0)
        1000.0 / preview.decode_pipeline_ms
    else
        0;
    var buffer: [192]u8 = undefined;
    const label = std.fmt.bufPrintZ(
        &buffer,
        "PIPE {d:.1} ms / {d:.1} fps   UP {d:.2} ms   DRAW {d:.3} ms   Q {d}/4   DROP {d}   WAIT {d}",
        .{
            preview.decode_pipeline_ms,
            pipeline_fps,
            preview.upload_ms,
            draw_texture_ms,
            preview.queued_frames,
            preview.dropped_frames,
            preview.underruns,
        },
    ) catch "DIAGNÓSTICO INDISPONÍVEL";
    const label_size = fonts.measure(label, 10, .semibold);
    const pill = rl.Rectangle{
        .x = viewport.x + 10,
        .y = viewport.y + 10,
        .width = @min(viewport.width - 20, label_size.x + 18),
        .height = 24,
    };
    rl.drawRectangleRounded(pill, 0.4, 6, rl.Color.init(0, 0, 0, 190));
    rl.beginScissorMode(
        @intFromFloat(@floor(pill.x + 9)),
        @intFromFloat(@floor(pill.y)),
        @intFromFloat(@ceil(@max(1, pill.width - 18))),
        @intFromFloat(@ceil(pill.height)),
    );
    components.textStrong(label, pill.x + 9, pill.y + 7, 10, theme.text);
    rl.endScissorMode();
}

fn drawEmptyPreview(viewport: rl.Rectangle) bool {
    const center_x = viewport.x + viewport.width * 0.5;
    const center_y = viewport.y + viewport.height * 0.5 - 12;
    const action = rl.Rectangle{
        .x = center_x - 170,
        .y = center_y - 60,
        .width = 340,
        .height = 126,
    };
    const hovered = rl.checkCollisionPointRec(rl.getMousePosition(), action);
    if (hovered) {
        rl.drawRectangleRounded(action, 0.08, 8, theme.surface_raised);
        rl.drawRectangleRoundedLinesEx(action, 0.08, 8, 1, theme.border_soft);
    }
    const icon = rl.Rectangle{
        .x = center_x - 24,
        .y = center_y - 34,
        .width = 48,
        .height = 34,
    };
    rl.drawRectangleRounded(icon, 0.16, 6, if (hovered) theme.surface_hover else theme.surface_alt);
    rl.drawRectangleRoundedLinesEx(icon, 0.16, 6, 1, theme.border);
    rl.drawTriangle(
        .{ .x = center_x - 5, .y = icon.y + 9 },
        .{ .x = center_x - 5, .y = icon.y + 25 },
        .{ .x = center_x + 8, .y = icon.y + 17 },
        theme.accent,
    );

    const title = if (hovered)
        "Clique para escolher um vídeo"
    else
        "Clique ou arraste um vídeo aqui";
    const title_size = fonts.measure(title, 14, .semibold);
    components.textStrong(title, center_x - title_size.x * 0.5, center_y + 14, 14, theme.text);
    const detail = "MP4, MOV, MKV, AVI, WebM, M4V, MTS ou M2TS";
    const detail_size = fonts.measure(detail, 11, .regular);
    components.text(detail, center_x - detail_size.x * 0.5, center_y + 38, 11, theme.text_muted);
    return hovered and rl.isMouseButtonPressed(.left);
}

fn drawClippedText(
    label: [:0]const u8,
    x: f32,
    y: f32,
    width: f32,
    size: i32,
    color: rl.Color,
) void {
    rl.beginScissorMode(
        @intFromFloat(@floor(x)),
        @intFromFloat(@floor(y)),
        @intFromFloat(@ceil(width)),
        size + 5,
    );
    components.text(label, x, y, size, color);
    rl.endScissorMode();
}

fn drawParameters(panel: rl.Rectangle, snapshot: state_mod.Snapshot) UiResult {
    var result = UiResult{ .parameters = snapshot.parameters };
    components.card(panel);
    const x = panel.x + 20;
    const content_w = panel.width - 40;

    components.textStrong("Inspetor", x, panel.y + 17, 18, theme.text);
    drawClippedText(
        if (snapshot.media.hasInput()) snapshot.media.name() else "Configurações do projeto",
        x,
        panel.y + 45,
        content_w,
        11,
        theme.text_muted,
    );
    rl.drawLineEx(.{ .x = x, .y = panel.y + 72 }, .{ .x = panel.x + panel.width - 20, .y = panel.y + 72 }, 1, theme.border_soft);

    components.textStrong("EFEITOS DO CLIPE", x, panel.y + 88, 10, theme.text_subtle);
    const effect_card = rl.Rectangle{
        .x = x,
        .y = panel.y + 106,
        .width = content_w,
        .height = 226,
    };
    rl.drawRectangleRounded(effect_card, 0.05, 8, theme.surface_raised);
    rl.drawRectangleRoundedLinesEx(effect_card, 0.05, 8, 1, theme.border_soft);
    rl.drawCircleV(.{ .x = effect_card.x + 18, .y = effect_card.y + 22 }, 5, theme.accent);
    components.textStrong("Estabilização", effect_card.x + 31, effect_card.y + 15, 12, theme.text);
    _ = components.checkbox(
        effect_card.x + effect_card.width - 76,
        effect_card.y + 13,
        "Ativa",
        &result.parameters.stabilization_enabled,
    );
    rl.drawLineEx(
        .{ .x = effect_card.x + 12, .y = effect_card.y + 44 },
        .{ .x = effect_card.x + effect_card.width - 12, .y = effect_card.y + 44 },
        1,
        theme.border_soft,
    );

    const effect_x = effect_card.x + 12;
    const effect_w = effect_card.width - 24;
    const left = rl.Rectangle{ .x = effect_x, .y = effect_card.y + 57, .width = effect_w * 0.5 - 4, .height = 32 };
    const right = rl.Rectangle{ .x = effect_x + effect_w * 0.5 + 4, .y = left.y, .width = effect_w * 0.5 - 4, .height = 32 };
    const effect_enabled = result.parameters.stabilization_enabled;
    if (components.button(left, "MOVIMENTO", if (result.parameters.mode == .motion) .primary else .secondary, effect_enabled)) result.parameters.mode = .motion;
    if (components.button(right, "DISTORÇÃO", if (result.parameters.mode == .distortion) .primary else .secondary, false)) result.parameters.mode = .distortion;

    _ = components.slider(.{ .x = effect_x, .y = effect_card.y + 96, .width = effect_w, .height = 44 }, "Suavidade", &result.parameters.smoothness, 0, 100, "%", effect_enabled);
    _ = components.slider(.{ .x = effect_x, .y = effect_card.y + 145, .width = effect_w, .height = 44 }, "Recorte", &result.parameters.crop, 0, 30, "%", effect_enabled);
    _ = components.toggle(effect_x, effect_card.y + 198, "Recorte automático", &result.parameters.dynamic_crop, effect_enabled);

    components.textStrong("EXPORTAÇÃO", x, panel.y + 352, 10, theme.text_subtle);
    const quality_gap: f32 = 5;
    const quality_width = (content_w - quality_gap * 2) / 3;
    const quality_y = panel.y + 370;
    if (components.button(
        .{ .x = x, .y = quality_y, .width = quality_width, .height = 34 },
        "ALTA",
        if (result.parameters.export_quality == .high) .primary else .secondary,
        effect_enabled,
    )) result.parameters.export_quality = .high;
    if (components.button(
        .{ .x = x + quality_width + quality_gap, .y = quality_y, .width = quality_width, .height = 34 },
        "PADRÃO",
        if (result.parameters.export_quality == .balanced) .primary else .secondary,
        effect_enabled,
    )) result.parameters.export_quality = .balanced;
    if (components.button(
        .{ .x = x + (quality_width + quality_gap) * 2, .y = quality_y, .width = quality_width, .height = 34 },
        "LEVE",
        if (result.parameters.export_quality == .compact) .primary else .secondary,
        effect_enabled,
    )) result.parameters.export_quality = .compact;

    const busy = snapshot.phase.isBusy();
    const button_y = panel.y + panel.height - 58;
    drawOutputNote(
        .{ .x = x, .y = button_y - 76, .width = content_w, .height = 60 },
        snapshot,
    );
    if (busy) {
        result.cancel_requested = components.button(.{ .x = x, .y = button_y, .width = content_w, .height = 42 }, "CANCELAR", .danger, true);
    } else {
        result.start_requested = components.button(
            .{ .x = x, .y = button_y, .width = content_w, .height = 42 },
            "EXPORTAR VÍDEO",
            .primary,
            snapshot.media.hasInput(),
        );
    }
    return result;
}

fn drawOutputNote(rect: rl.Rectangle, snapshot: state_mod.Snapshot) void {
    const color = switch (snapshot.phase) {
        .completed => theme.success,
        .failed => theme.danger,
        else => theme.accent,
    };
    rl.drawRectangleRounded(rect, 0.12, 8, theme.surface_raised);
    rl.drawRectangleRoundedLinesEx(rect, 0.12, 8, 1, theme.border_soft);
    rl.drawRectangleRounded(
        .{ .x = rect.x, .y = rect.y + 9, .width = 3, .height = rect.height - 18 },
        1,
        4,
        color,
    );

    if (snapshot.phase == .completed) {
        components.textStrong("VÍDEO CONCLUÍDO", rect.x + 14, rect.y + 10, 10, theme.success);
        components.text("A saída foi salva ao lado do original.", rect.x + 14, rect.y + 31, 11, theme.text_muted);
    } else if (snapshot.phase == .failed) {
        components.textStrong("NÃO FOI POSSÍVEL CONCLUIR", rect.x + 14, rect.y + 10, 10, theme.danger);
        drawClippedText(snapshot.status(), rect.x + 14, rect.y + 31, rect.width - 28, 11, theme.text_muted);
    } else if (snapshot.media.hasInput()) {
        components.textStrong("ORIGINAL PRESERVADO", rect.x + 14, rect.y + 10, 10, theme.accent_hover);
        components.text("A saída será criada na mesma pasta.", rect.x + 14, rect.y + 31, 11, theme.text_muted);
    } else {
        components.textStrong("COMECE IMPORTANDO UM VÍDEO", rect.x + 14, rect.y + 10, 10, theme.accent_hover);
        components.text("O arquivo original não será alterado.", rect.x + 14, rect.y + 31, 11, theme.text_muted);
    }
}

const PlayerActions = struct {
    import_requested: bool = false,
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
    const enabled = preview.loaded and !preview.failed and
        !preview.preparing_proxy and !snapshot.phase.isBusy();
    const progress = if (preview.preparing_proxy)
        preview.proxy_progress
    else
        preview.progress();
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
        (rl.isMouseButtonDown(.left) or rl.isMouseButtonReleased(.left)))
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

    var status_buffer: [64]u8 = undefined;
    const status: [:0]const u8 = if (preview.failed)
        "Preview indisponível"
    else if (!preview.loaded)
        "Importe um vídeo"
    else if (preview.preparing_proxy)
        std.fmt.bufPrintZ(
            &status_buffer,
            "Preparando prévia {d:.0}%",
            .{preview.proxy_progress * 100},
        ) catch "Preparando prévia..."
    else if (preview.proxy_failed)
        "Proxy falhou; usando original"
    else if (preview.seeking)
        "Buscando quadro..."
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
    components.card(area);
    components.textStrong("Linha do tempo", area.x + 18, area.y + 14, 14, theme.text);

    var time_buffer: [40]u8 = undefined;
    const time_text = formatPlayerTime(&time_buffer, preview.position_seconds, preview.duration_seconds);
    const time_measure = fonts.measure(time_text, 11, .semibold);
    const time_pill = rl.Rectangle{
        .x = area.x + area.width - time_measure.x - 34,
        .y = area.y + 10,
        .width = time_measure.x + 18,
        .height = 25,
    };
    rl.drawRectangleRounded(time_pill, 0.5, 8, theme.surface_alt);
    components.textStrong(time_text, time_pill.x + 9, time_pill.y + 7, 11, theme.text_muted);

    const track = rl.Rectangle{
        .x = area.x + 18,
        .y = area.y + 48,
        .width = area.width - 36,
        .height = 88,
    };
    rl.drawRectangleRounded(track, 0.06, 8, theme.surface_raised);
    rl.drawRectangleRoundedLinesEx(track, 0.06, 8, 1, theme.border_soft);

    const track_header = rl.Rectangle{
        .x = track.x,
        .y = track.y,
        .width = 58,
        .height = track.height,
    };
    rl.drawRectangleRounded(track_header, 0.06, 8, theme.surface_alt);
    rl.drawLineEx(
        .{ .x = track_header.x + track_header.width, .y = track.y },
        .{ .x = track_header.x + track_header.width, .y = track.y + track.height },
        1,
        theme.border,
    );
    components.textStrong("V1", track_header.x + 20, track_header.y + 29, 12, theme.text);
    components.text("VÍDEO", track_header.x + 13, track_header.y + 51, 8, theme.text_subtle);

    const lane = rl.Rectangle{
        .x = track.x + track_header.width + 8,
        .y = track.y,
        .width = track.width - track_header.width - 16,
        .height = track.height,
    };

    var tick: usize = 0;
    while (tick <= 10) : (tick += 1) {
        const x = lane.x + lane.width * @as(f32, @floatFromInt(tick)) / 10.0;
        const tick_height: f32 = if (tick % 5 == 0) 2 else 5;
        rl.drawLineEx(
            .{ .x = x, .y = track.y - 10 },
            .{ .x = x, .y = track.y - tick_height },
            1,
            theme.border,
        );
    }

    if (snapshot.media.hasInput()) {
        const clip = rl.Rectangle{
            .x = lane.x,
            .y = lane.y + 9,
            .width = lane.width,
            .height = lane.height - 18,
        };
        rl.drawRectangleRounded(clip, 0.08, 6, theme.accent_subtle);
        drawTimelineThumbnails(clip, preview);
        if (preview.thumbnail_texture != null or preview.ready) {
            rl.drawRectangleRec(clip, rl.Color.init(5, 8, 16, 112));
        }

        const inner_clip = rl.Rectangle{
            .x = clip.x + 1,
            .y = clip.y + 1,
            .width = clip.width - 2,
            .height = clip.height - 2,
        };
        rl.drawRectangleRoundedLinesEx(inner_clip, 0.08, 6, 1, rl.Color.init(255, 255, 255, 25));
        rl.drawRectangleRoundedLinesEx(clip, 0.08, 6, 1, theme.accent);

        drawClippedText(
            snapshot.media.name(),
            clip.x + 12,
            clip.y + 12,
            clip.width - 120,
            12,
            theme.text,
        );
        const effect_label = if (snapshot.parameters.stabilization_enabled)
            "fx  Estabilização"
        else
            "fx  Estabilização desativada";
        components.textStrong(
            effect_label,
            clip.x + 12,
            clip.y + 39,
            9,
            if (snapshot.parameters.stabilization_enabled) theme.accent_hover else theme.text_subtle,
        );

        if (clip.width > 150) {
            const dur_total: u64 = @intFromFloat(@max(0.0, @floor(preview.duration_seconds)));
            var dur_buf: [16]u8 = undefined;
            const dur_text = std.fmt.bufPrintZ(
                &dur_buf,
                "{d:0>2}:{d:0>2}",
                .{ dur_total / 60, dur_total % 60 },
            ) catch "00:00";

            const dur_size = fonts.measure(dur_text, 11, .regular);
            components.text(dur_text, clip.x + clip.width - dur_size.x - 12, clip.y + 27, 11, theme.accent);
        }

        const playhead_x = lane.x + lane.width * preview.progress();
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
        const empty_text = "A mídia importada aparecerá aqui";
        const empty_size = fonts.measure(empty_text, 12, .regular);
        components.text(
            empty_text,
            lane.x + (lane.width - empty_size.x) * 0.5,
            lane.y + 36,
            12,
            theme.text_muted,
        );
    }

    if (snapshot.phase.isBusy()) {
        components.progressBar(.{
            .x = area.x + 18,
            .y = area.y + 151,
            .width = area.width - 90,
            .height = 8,
        }, snapshot.progress);
        var percent_buffer: [16]u8 = undefined;
        const percent = std.fmt.bufPrintZ(
            &percent_buffer,
            "{d:.0}%",
            .{snapshot.progress * 100.0},
        ) catch "--";
        components.text(percent, area.x + area.width - 58, area.y + 146, 14, theme.text);
        components.text(snapshot.status(), area.x + 18, area.y + 169, 12, theme.text_muted);
        var metrics_buffer: [96]u8 = undefined;
        const metrics = formatProcessingMetrics(&metrics_buffer, snapshot);
        if (metrics.len > 0) {
            const metrics_size = fonts.measure(metrics, 12, .regular);
            components.text(
                metrics,
                area.x + area.width - metrics_size.x - 18,
                area.y + 169,
                12,
                theme.text,
            );
        }
    } else {
        components.text(
            if (snapshot.media.hasInput()) "1 faixa de vídeo" else "Importe uma mídia para começar.",
            area.x + 18,
            area.y + 160,
            12,
            theme.text_muted,
        );
    }
}

fn drawTimelineThumbnails(clip: rl.Rectangle, preview: preview_player.View) void {
    const has_strip = preview.thumbnail_texture != null and
        preview.thumbnail_count > 0 and
        preview.thumbnail_cell_width > 0 and
        preview.thumbnail_cell_height > 0;
    const texture = if (has_strip)
        preview.thumbnail_texture.?
    else
        preview.texture orelse return;
    if (!has_strip and !preview.ready) return;
    const image_count = if (has_strip) preview.thumbnail_count else preview_thumbnails.count;
    const source_width = if (has_strip) preview.thumbnail_cell_width else preview.width;
    const source_height = if (has_strip) preview.thumbnail_cell_height else preview.height;

    rl.beginScissorMode(
        @intFromFloat(@floor(clip.x + 1)),
        @intFromFloat(@floor(clip.y + 1)),
        @intFromFloat(@ceil(@max(1, clip.width - 2))),
        @intFromFloat(@ceil(@max(1, clip.height - 2))),
    );
    defer rl.endScissorMode();
    const destination_width = clip.width /
        @as(f32, @floatFromInt(image_count));
    for (0..image_count) |index| {
        const cell = rl.Rectangle{
            .x = clip.x + destination_width * @as(f32, @floatFromInt(index)),
            .y = clip.y,
            .width = destination_width + 1,
            .height = clip.height,
        };
        const destination = if (has_strip)
            cell
        else
            fitAspect(
                cell,
                @as(f32, @floatFromInt(source_width)) /
                    @as(f32, @floatFromInt(source_height)),
            );
        rl.drawTexturePro(
            texture,
            .{
                .x = if (has_strip)
                    @as(f32, @floatFromInt(index * source_width))
                else
                    0,
                .y = 0,
                .width = @floatFromInt(source_width),
                .height = @floatFromInt(source_height),
            },
            destination,
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
    }
}

fn formatProcessingMetrics(
    buffer: *[96]u8,
    snapshot: state_mod.Snapshot,
) [:0]const u8 {
    const total = snapshot.total_frames orelse {
        if (snapshot.processed_frame == 0) return "";
        if (snapshot.processing_speed <= 0) {
            return std.fmt.bufPrintZ(
                buffer,
                "{d} frames",
                .{snapshot.processed_frame},
            ) catch "";
        }
        return std.fmt.bufPrintZ(
            buffer,
            "{d} frames | {d:.1} fps",
            .{ snapshot.processed_frame, snapshot.processing_speed },
        ) catch "";
    };
    if (snapshot.processing_speed <= 0 or snapshot.processed_frame >= total) {
        return std.fmt.bufPrintZ(
            buffer,
            "{d}/{d} frames",
            .{ snapshot.processed_frame, total },
        ) catch "";
    }

    const remaining_frames = total - snapshot.processed_frame;
    const remaining_seconds: u64 = @intFromFloat(@ceil(
        @as(f64, @floatFromInt(remaining_frames)) /
            @as(f64, snapshot.processing_speed),
    ));
    return std.fmt.bufPrintZ(
        buffer,
        "{d:.1} fps | ETA {d:0>2}:{d:0>2}",
        .{
            snapshot.processing_speed,
            remaining_seconds / 60,
            remaining_seconds % 60,
        },
    ) catch "";
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
