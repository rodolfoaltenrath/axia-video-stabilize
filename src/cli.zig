const std = @import("std");
const app_state = @import("app_state.zig");
const media = @import("core/media.zig");
const engine = @import("engine/engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try engine.ensureReady();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2 or args.len > 3) {
        std.debug.print("uso: axia-cli <entrada> [saida.mp4]\n", .{});
        return error.InvalidArguments;
    }

    const input_path = args[1];
    var output_buffer: [app_state.max_path_bytes]u8 = undefined;
    const output_path = if (args.len == 3)
        args[2]
    else
        try media.deriveOutputPath(&output_buffer, input_path);

    std.debug.print("Axia: iniciando pipeline nativo para {s}\n", .{input_path});
    var progress = CliProgress{};
    const result = try engine.exporter.Exporter.run(
        allocator,
        input_path,
        output_path,
        .{
            .observer = .{
                .context = &progress,
                .on_progress = CliProgress.onProgress,
            },
        },
    );
    std.debug.print(
        "Axia: concluído em {s} ({d} frames, {d} faixas de áudio)\n",
        .{ output_path, result.frames, result.audio_streams },
    );
}

const CliProgress = struct {
    fn onProgress(
        raw_context: ?*anyopaque,
        progress: engine.exporter.Progress,
    ) void {
        _ = raw_context;
        const total = progress.total_frames orelse 0;
        std.debug.print(
            "Axia: {s} frame {d}/{d}\n",
            .{ stageLabel(progress.stage), progress.processed_frames, total },
        );
    }

    fn stageLabel(stage: engine.exporter.Stage) []const u8 {
        return switch (stage) {
            .analyzing => "análise",
            .rendering => "render",
            .muxing => "mux",
            .completed => "concluído",
        };
    }
};
