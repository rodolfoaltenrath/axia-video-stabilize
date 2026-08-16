const std = @import("std");
const rl = @import("raylib");
const build_options = @import("build_options");
const app_state = @import("app_state.zig");
const media = @import("core/media.zig");
const file_dialog = @import("platform/file_dialog.zig");
const thread_pool = @import("utils/thread_pool.zig");
const fonts = @import("ui/fonts.zig");
const preview_player = @import("ui/preview_player.zig");
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

    rl.setConfigFlags(.{
        .window_resizable = true,
        .window_maximized = true,
        .msaa_4x_hint = true,
        .vsync_hint = true,
    });
    var title_buffer: [128]u8 = undefined;
    const window_title = try std.fmt.bufPrintZ(
        &title_buffer,
        "Axia {s} - Estabilização de Vídeo",
        .{build_options.version},
    );
    rl.initWindow(1280, 720, window_title);
    defer rl.closeWindow();
    rl.setWindowMinSize(960, 640);
    if (!rl.isWindowMaximized()) rl.maximizeWindow();
    rl.setTargetFPS(60);

    try fonts.init();
    defer fonts.deinit();
    var preview = preview_player.Player.init(allocator);
    defer preview.deinit();
    var import_selector = file_dialog.AsyncSelector.init(allocator);
    defer import_selector.deinit();

    while (!rl.windowShouldClose()) {
        if (import_selector.poll()) |selection| {
            finishImport(allocator, &state, &preview, selection);
        }
        preview.update(rl.getFrameTime());
        const snapshot = state.snapshot();

        rl.beginDrawing();
        const result = window.draw(snapshot, preview.view());
        rl.endDrawing();

        state.setParameters(result.parameters);
        if (result.import_requested) requestImport(&import_selector, &state);
        if (result.preview_toggle_requested) {
            preview.togglePlayback() catch |err| reportPreviewError(&state, err);
        }
        if (result.preview_seek_ratio) |ratio| {
            preview.seek(@as(f64, @floatCast(ratio)) * preview.view().duration_seconds) catch |err|
                reportPreviewError(&state, err);
        }
        if (result.cancel_requested) state.requestCancel();
        if (result.start_requested) {
            preview.pause();
            _ = workers.submit();
        }
    }
}

fn requestImport(
    selector: *file_dialog.AsyncSelector,
    state: *app_state.AppState,
) void {
    _ = selector.start() catch |err| {
        std.log.err("file dialog thread error: {s}", .{@errorName(err)});
        state.setMessage("Não foi possível iniciar o seletor de vídeos.");
        return;
    };
}

fn finishImport(
    allocator: std.mem.Allocator,
    state: *app_state.AppState,
    preview: *preview_player.Player,
    selection: file_dialog.Selection,
) void {
    const selected_path = switch (selection) {
        .selected => |path| path,
        .cancelled => return,
        .failed => |err| {
            reportFileDialogError(state, err);
            return;
        },
    };
    defer allocator.free(selected_path);

    if (!loadMedia(state, selected_path)) return;
    preview.load(selected_path) catch |err| reportPreviewError(state, err);
}

fn reportFileDialogError(
    state: *app_state.AppState,
    err: file_dialog.FileDialogError,
) void {
    state.setMessage(switch (err) {
        error.UnsupportedPlatform => "A importação por seletor ainda não está disponível neste sistema.",
        error.BackendUnavailable => "Instale Zenity ou KDialog para abrir o seletor de vídeos no Linux.",
        error.DialogFailed => "O sistema não conseguiu abrir o seletor de vídeos.",
        error.InvalidPathEncoding => "O caminho selecionado não pôde ser interpretado.",
        error.OutOfMemory => "Não há memória suficiente para importar o vídeo.",
    });
}

fn loadMedia(state: *app_state.AppState, input_path: []const u8) bool {
    var output_buffer: [app_state.max_path_bytes]u8 = undefined;
    const output_path = media.deriveOutputPath(&output_buffer, input_path) catch |err| {
        state.setMessage(switch (err) {
            error.UnsupportedFormat => "Formato não suportado. Use MP4, MOV, MKV, AVI, WebM, M4V, MTS ou M2TS.",
            error.OutputPathTooLong => "O caminho do vídeo é longo demais.",
            error.EmptyPath => "O arquivo selecionado não possui um caminho válido.",
        });
        return false;
    };
    if (!state.setMedia(input_path, output_path)) {
        state.setMessage("Não foi possível carregar o vídeo durante um processamento ativo.");
        return false;
    }
    return true;
}

fn reportPreviewError(state: *app_state.AppState, err: anyerror) void {
    std.log.err("preview error: {s}", .{@errorName(err)});
    state.setMessage("O vídeo foi importado, mas não foi possível carregar o preview.");
}
