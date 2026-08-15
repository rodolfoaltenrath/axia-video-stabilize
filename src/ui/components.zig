const std = @import("std");
const rl = @import("raylib");
const fonts = @import("fonts.zig");
const theme = @import("theme.zig");

pub const ButtonStyle = enum { primary, secondary, danger };

pub fn text(label: [:0]const u8, x: f32, y: f32, size: i32, color: rl.Color) void {
    fonts.draw(label, x, y, @floatFromInt(size), .regular, color);
}

pub fn textStrong(label: [:0]const u8, x: f32, y: f32, size: i32, color: rl.Color) void {
    fonts.draw(label, x, y, @floatFromInt(size), .semibold, color);
}

pub fn card(rect: rl.Rectangle) void {
    const shadow = rl.Rectangle{
        .x = rect.x,
        .y = rect.y + 4,
        .width = rect.width,
        .height = rect.height,
    };
    rl.drawRectangleRounded(shadow, 0.025, 10, theme.shadow);
    rl.drawRectangleRounded(rect, 0.025, 10, theme.surface);
    rl.drawRectangleRoundedLinesEx(rect, 0.025, 10, 1, theme.border_soft);
}

pub fn button(rect: rl.Rectangle, label: [:0]const u8, style: ButtonStyle, enabled: bool) bool {
    const mouse = rl.getMousePosition();
    const hovered = enabled and rl.checkCollisionPointRec(mouse, rect);
    const pressed = hovered and rl.isMouseButtonDown(.left);
    var color = switch (style) {
        .primary => theme.accent,
        .secondary => theme.surface_alt,
        .danger => theme.danger,
    };
    if (hovered) {
        color = switch (style) {
            .primary => theme.accent_hover,
            .secondary => theme.surface_hover,
            .danger => brighten(color, 14),
        };
    }
    if (!enabled) color = rl.Color.init(color.r, color.g, color.b, 90);

    var draw_rect = rect;
    if (pressed) draw_rect.y += 1;
    if (style != .secondary and enabled) {
        rl.drawRectangleRounded(.{
            .x = draw_rect.x,
            .y = draw_rect.y + 2,
            .width = draw_rect.width,
            .height = draw_rect.height,
        }, 0.18, 8, theme.shadow);
    }
    rl.drawRectangleRounded(draw_rect, 0.18, 8, color);
    rl.drawRectangleRoundedLinesEx(
        draw_rect,
        0.18,
        8,
        1.0,
        if (style == .secondary) theme.border else color,
    );

    const measured = fonts.measure(label, 15, .semibold);
    textStrong(
        label,
        draw_rect.x + (draw_rect.width - measured.x) / 2.0,
        draw_rect.y + (draw_rect.height - measured.y) / 2.0,
        15,
        if (enabled) theme.text else theme.text_subtle,
    );
    return hovered and rl.isMouseButtonPressed(.left);
}

pub fn slider(rect: rl.Rectangle, label: [:0]const u8, value: *f32, minimum: f32, maximum: f32, suffix: [:0]const u8) bool {
    var changed = false;
    const mouse = rl.getMousePosition();
    const hitbox = rl.Rectangle{
        .x = rect.x,
        .y = rect.y + 21,
        .width = rect.width,
        .height = 26,
    };
    const hovered = rl.checkCollisionPointRec(mouse, hitbox);
    if (rl.isMouseButtonDown(.left) and hovered) {
        const normalized = std.math.clamp((mouse.x - rect.x) / rect.width, 0.0, 1.0);
        value.* = minimum + normalized * (maximum - minimum);
        changed = true;
    }

    text(label, rect.x, rect.y, 14, theme.text_muted);
    var buffer: [48]u8 = undefined;
    const value_text = std.fmt.bufPrintZ(&buffer, "{d:.0}{s}", .{ value.*, suffix }) catch "--";
    const measured = fonts.measure(value_text, 14, .semibold);
    textStrong(value_text, rect.x + rect.width - measured.x, rect.y, 14, theme.text);

    const track = rl.Rectangle{ .x = rect.x, .y = rect.y + 31, .width = rect.width, .height = 5 };
    rl.drawRectangleRounded(track, 1.0, 6, if (hovered) theme.surface_hover else theme.border);
    const normalized = std.math.clamp((value.* - minimum) / (maximum - minimum), 0.0, 1.0);
    rl.drawRectangleRounded(.{ .x = track.x, .y = track.y, .width = track.width * normalized, .height = track.height }, 1.0, 6, theme.accent);
    const thumb = rl.Vector2{ .x = track.x + track.width * normalized, .y = track.y + track.height * 0.5 };
    rl.drawCircleV(thumb, if (hovered) 9 else 8, theme.text);
    rl.drawCircleV(thumb, if (hovered) 5 else 4, theme.accent);
    return changed;
}

pub fn toggle(x: f32, y: f32, label: [:0]const u8, value: *bool) bool {
    const rect = rl.Rectangle{ .x = x, .y = y, .width = 38, .height = 20 };
    const mouse = rl.getMousePosition();
    const label_size = fonts.measure(label, 14, .regular);
    const hitbox = rl.Rectangle{
        .x = x - 2,
        .y = y - 3,
        .width = 54 + label_size.x,
        .height = 26,
    };
    const hovered = rl.checkCollisionPointRec(mouse, hitbox);
    var changed = false;
    if (hovered and rl.isMouseButtonPressed(.left)) {
        value.* = !value.*;
        changed = true;
    }
    rl.drawRectangleRounded(
        rect,
        1.0,
        12,
        if (value.*)
            (if (hovered) theme.accent_hover else theme.accent)
        else if (hovered)
            theme.surface_hover
        else
            theme.border,
    );
    if (!value.*) rl.drawRectangleRoundedLinesEx(rect, 1.0, 12, 1, theme.border);
    rl.drawCircleV(.{ .x = if (value.*) x + 28 else x + 10, .y = y + 10 }, 7, theme.text);
    text(label, x + 50, y + 2, 14, if (hovered) theme.text else theme.text_muted);
    return changed;
}

pub fn progressBar(rect: rl.Rectangle, progress: f32) void {
    const amount = std.math.clamp(progress, 0.0, 1.0);
    rl.drawRectangleRounded(rect, 1.0, 8, theme.border);
    if (amount > 0) {
        rl.drawRectangleRounded(.{ .x = rect.x, .y = rect.y, .width = @max(8, rect.width * amount), .height = rect.height }, 1.0, 8, theme.accent);
    }
}

fn brighten(color: rl.Color, amount: u8) rl.Color {
    return .{
        .r = color.r +| amount,
        .g = color.g +| amount,
        .b = color.b +| amount,
        .a = color.a,
    };
}
