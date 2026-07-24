const rl = @import("raylib");

pub const Weight = enum { regular, semibold };

const regular_data = @embedFile("../assets/fonts/Montserrat-Regular.ttf");
const semibold_data = @embedFile("../assets/fonts/Montserrat-SemiBold.ttf");

// Basic Latin + Latin-1 Supplement covers Portuguese diacritics such as
// á, â, ã, ç, é, í, ó and õ while keeping the texture atlas compact.
var latin_codepoints = makeLatinCodepoints();
var regular: rl.Font = undefined;
var semibold: rl.Font = undefined;
var initialized = false;

pub fn init() !void {
    regular = try rl.loadFontFromMemory(".ttf", regular_data[0..], 48, latin_codepoints[0..]);
    errdefer rl.unloadFont(regular);
    semibold = try rl.loadFontFromMemory(".ttf", semibold_data[0..], 48, latin_codepoints[0..]);

    rl.setTextureFilter(regular.texture, .bilinear);
    rl.setTextureFilter(semibold.texture, .bilinear);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    rl.unloadFont(semibold);
    rl.unloadFont(regular);
    initialized = false;
}

pub fn draw(label: [:0]const u8, x: f32, y: f32, size: f32, weight: Weight, color: rl.Color) void {
    rl.drawTextEx(select(weight), label, .{ .x = x, .y = y }, size, spacing(size), color);
}

pub fn measure(label: [:0]const u8, size: f32, weight: Weight) rl.Vector2 {
    return rl.measureTextEx(select(weight), label, size, spacing(size));
}

fn select(weight: Weight) rl.Font {
    return switch (weight) {
        .regular => regular,
        .semibold => semibold,
    };
}

fn spacing(size: f32) f32 {
    return @max(0.2, size * 0.015);
}

fn makeLatinCodepoints() [224]i32 {
    var result: [224]i32 = undefined;
    for (&result, 32..) |*codepoint, value| codepoint.* = @intCast(value);
    return result;
}
