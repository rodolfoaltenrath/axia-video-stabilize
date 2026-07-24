const std = @import("std");
const rl = @import("raylib");
const app_state = @import("app_state.zig");
const media = @import("core/media.zig");
const thread_pool = @import("utils/thread_pool.zig");
const fonts = @import("ui/fonts.zig");
const window = @import("ui/window.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) std.log.err("memory leak detected", .{});
    }
    const allocator = gpa.allocator();

    var state = app_state.AppState{};
    const workers = try thread_pool.ThreadPool.create(allocator, &state);
    defer workers.destroy();

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true, .vsync_hint = true });
    rl.initWindow(1360, 820, "Axia - Estabilização de Vídeo");
    defer rl.closeWindow();
    rl.setWindowMinSize(960, 640);
    rl.setTargetFPS(60);

    try fonts.init();
    defer fonts.deinit();

    while (!rl.windowShouldClose()) {
        handleDroppedMedia(&state);
        const snapshot = state.snapshot();

        rl.beginDrawing();
        const result = window.draw(snapshot);
        rl.endDrawing();

        state.setParameters(result.parameters);
        if (result.cancel_requested) state.requestCancel();
        if (result.start_requested) _ = workers.submit();
    }
}

fn handleDroppedMedia(state: *app_state.AppState) void {
    if (!rl.isFileDropped()) return;
    const files = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(files);
    if (files.count == 0 or files.paths == null or files.paths[0] == null) return;

    const raw_path: [*:0]const u8 = @ptrCast(files.paths[0]);
    const input_path = std.mem.span(raw_path);
    var output_buffer: [app_state.max_path_bytes]u8 = undefined;
    const output_path = media.deriveOutputPath(&output_buffer, input_path) catch |err| {
        state.setMessage(switch (err) {
            error.UnsupportedFormat => "Formato não suportado. Use MP4, MOV, MKV, AVI, WebM, M4V, MTS ou M2TS.",
            error.OutputPathTooLong => "O caminho do vídeo é longo demais.",
            error.EmptyPath => "O arquivo arrastado não possui um caminho válido.",
        });
        return;
    };
    if (!state.setMedia(input_path, output_path)) {
        state.setMessage("Não foi possível carregar o vídeo durante um processamento ativo.");
    }
}
