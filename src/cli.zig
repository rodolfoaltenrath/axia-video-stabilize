const std = @import("std");
const app_state = @import("app_state.zig");
const ffmpeg_cli = @import("core/ffmpeg_cli.zig");
const media = @import("core/media.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    std.debug.print("Axia: lendo metadados de {s}\n", .{input_path});
    const info = try ffmpeg_cli.probe(allocator, input_path);
    std.debug.print(
        "Axia: {d}x{d}, {d:.3} fps, {d:.3} s\n",
        .{ info.width, info.height, info.framesPerSecond(), info.duration_seconds },
    );

    const temp_directory = try getTempDirectory(allocator);
    defer allocator.free(temp_directory);
    const transform_name = try std.fmt.allocPrint(
        allocator,
        "axia-cli-{d}.trf",
        .{std.time.nanoTimestamp()},
    );
    defer allocator.free(transform_name);
    const transform_path = try std.fs.path.join(allocator, &.{ temp_directory, transform_name });
    defer allocator.free(transform_path);
    defer std.fs.deleteFileAbsolute(transform_path) catch {};

    std.debug.print("Axia: analisando movimento (passo 1/2)\n", .{});
    var analyze_progress = CliProgress{ .label = "análise", .total_frames = info.estimatedFrameCount() };
    try ffmpeg_cli.analyze(
        allocator,
        input_path,
        temp_directory,
        transform_name,
        analyze_progress.observer(),
    );

    std.debug.print("Axia: estabilizando e exportando (passo 2/2)\n", .{});
    var render_progress = CliProgress{ .label = "render", .total_frames = info.estimatedFrameCount() };
    try ffmpeg_cli.render(
        allocator,
        input_path,
        output_path,
        temp_directory,
        transform_name,
        .{},
        info,
        render_progress.observer(),
    );
    std.debug.print("Axia: concluído em {s}\n", .{output_path});
}

const CliProgress = struct {
    label: []const u8,
    total_frames: u64,

    fn observer(self: *CliProgress) ffmpeg_cli.Observer {
        return .{ .context = self, .on_progress = onProgress };
    }

    fn onProgress(raw_context: ?*anyopaque, progress: ffmpeg_cli.Progress) void {
        const self: *CliProgress = @ptrCast(@alignCast(raw_context.?));
        std.debug.print(
            "Axia: {s} frame {d}/{d} ({d:.1}x)\n",
            .{ self.label, @min(progress.frame, self.total_frames), self.total_frames, progress.speed },
        );
    }
};

fn getTempDirectory(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "TEMP") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "TMP"),
        else => return err,
    };
}
