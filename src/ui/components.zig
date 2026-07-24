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

pub fn button(rect: rl.Rectangle, label: [:0]const u8, style: ButtonStyle, enabled: bool) bool {
    const mouse = rl.getMousePosition();
    const hovered = enabled and rl.checkCollisionPointRec(mouse, rect);
    var color = switch (style) {
        .primary => theme.accent,
        .secondary => theme.surface_alt,
        .danger => theme.danger,
    };
    if (hovered) color = brighten(color, 18);
    if (!enabled) color = rl.Color.init(color.r, color.g, color.b, 90);
    rl.drawRectangleRounded(rect, 0.18, 8, color);
    if (style == .secondary) rl.drawRectangleRoundedLinesEx(rect, 0.18, 8, 1.0, theme.border);

    const measured = fonts.measure(label, 15, .semibold);
    textStrong(label, rect.x + (rect.width - measured.x) / 2.0, rect.y + 10.0, 15, if (enabled) theme.text else theme.text_muted);
    return hovered and rl.isMouseButtonPressed(.left);
}

pub fn slider(rect: rl.Rectangle, label: [:0]const u8, value: *f32, minimum: f32, maximum: f32, suffix: [:0]const u8) bool {
    var changed = false;
    const mouse = rl.getMousePosition();
    if (rl.isMouseButtonDown(.left) and rl.checkCollisionPointRec(mouse, .{ .x = rect.x, .y = rect.y + 24, .width = rect.width, .height = 20 })) {
        const normalized = std.math.clamp((mouse.x - rect.x) / rect.width, 0.0, 1.0);
        value.* = minimum + normalized * (maximum - minimum);
        changed = true;
    }

    text(label, rect.x, rect.y, 14, theme.text_muted);
    var buffer: [48]u8 = undefined;
    const value_text = std.fmt.bufPrintZ(&buffer, "{d:.0}{s}", .{ value.*, suffix }) catch "--";
    const measured = fonts.measure(value_text, 14, .semibold);
    textStrong(value_text, rect.x + rect.width - measured.x, rect.y, 14, theme.text);

    const track = rl.Rectangle{ .x = rect.x, .y = rect.y + 31, .width = rect.width, .height = 4 };
    rl.drawRectangleRounded(track, 1.0, 6, theme.border);
    const normalized = (value.* - minimum) / (maximum - minimum);
    rl.drawRectangleRounded(.{ .x = track.x, .y = track.y, .width = track.width * normalized, .height = track.height }, 1.0, 6, theme.accent);
    rl.drawCircleV(.{ .x = track.x + track.width * normalized, .y = track.y + 2 }, 7, theme.text);
    rl.drawCircleV(.{ .x = track.x + track.width * normalized, .y = track.y + 2 }, 4, theme.accent);
    return changed;
}

pub fn toggle(x: f32, y: f32, label: [:0]const u8, value: *bool) bool {
    const rect = rl.Rectangle{ .x = x, .y = y, .width = 38, .height = 20 };
    const mouse = rl.getMousePosition();
    var changed = false;
    if (rl.checkCollisionPointRec(mouse, rect) and rl.isMouseButtonPressed(.left)) {
        value.* = !value.*;
        changed = true;
    }
    rl.drawRectangleRounded(rect, 1.0, 12, if (value.*) theme.accent else theme.border);
    rl.drawCircleV(.{ .x = if (value.*) x + 28 else x + 10, .y = y + 10 }, 7, theme.text);
    text(label, x + 50, y + 2, 14, theme.text);
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
