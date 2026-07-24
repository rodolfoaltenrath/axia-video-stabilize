const std = @import("std");
const state_mod = @import("../app_state.zig");
const stabilizer = @import("stabilizer.zig");

pub const CliError = error{
    ToolNotFound,
    ProbeFailed,
    InvalidProbeOutput,
    AnalyzeFailed,
    RenderFailed,
    InvalidFrameRate,
};

pub const ProbeInfo = struct {
    width: u32,
    height: u32,
    frame_rate_numerator: u32,
    frame_rate_denominator: u32,
    duration_seconds: f64,
    frame_count: ?u64 = null,

    pub fn framesPerSecond(self: ProbeInfo) f64 {
        return @as(f64, @floatFromInt(self.frame_rate_numerator)) /
            @as(f64, @floatFromInt(self.frame_rate_denominator));
    }
};

pub fn probe(allocator: std.mem.Allocator, input_path: []const u8) !ProbeInfo {
    const executable_override = std.process.getEnvVarOwned(allocator, "AXIA_FFPROBE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (executable_override) |path| allocator.free(path);
    const executable = executable_override orelse "ffprobe";

    const argv = [_][]const u8{
        executable,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,avg_frame_rate,nb_frames:format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=0",
        input_path,
    };
    const result = run(allocator, &argv, null, error.ProbeFailed) catch |err| switch (err) {
        error.FileNotFound => return error.ToolNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseProbeOutput(result.stdout);
}

pub fn analyze(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    working_directory: []const u8,
    transform_file_name: []const u8,
) !void {
    const executable_override = std.process.getEnvVarOwned(allocator, "AXIA_FFMPEG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (executable_override) |path| allocator.free(path);
    const executable = executable_override orelse "ffmpeg";

    const filter = try std.fmt.allocPrint(
        allocator,
        "vidstabdetect=shakiness=7:accuracy=15:stepsize=6:mincontrast=0.20:result={s}",
        .{transform_file_name},
    );
    defer allocator.free(filter);

    const argv = [_][]const u8{
        executable,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-vf",
        filter,
        "-an",
        "-f",
        "null",
        "-",
    };
    const result = run(allocator, &argv, working_directory, error.AnalyzeFailed) catch |err| switch (err) {
        error.FileNotFound => return error.ToolNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

pub fn render(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    working_directory: []const u8,
    transform_file_name: []const u8,
    parameters: state_mod.Parameters,
    info: ProbeInfo,
) !void {
    const executable_override = std.process.getEnvVarOwned(allocator, "AXIA_FFMPEG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (executable_override) |path| allocator.free(path);
    const executable = executable_override orelse "ffmpeg";

    const fps = info.framesPerSecond();
    if (!std.math.isFinite(fps) or fps <= 0) return error.InvalidFrameRate;
    const smoothing = stabilizer.radiusFromSmoothness(parameters.smoothness, @floatCast(fps));
    const optzoom: u8 = if (parameters.dynamic_crop) 2 else 1;
    const crop = std.math.clamp(parameters.crop, 0.0, 30.0);
    const filter = try std.fmt.allocPrint(
        allocator,
        "vidstabtransform=input={s}:smoothing={d}:optzoom={d}:zoom={d:.2}:interpol=bicubic,unsharp=5:5:0.35:3:3:0",
        .{ transform_file_name, smoothing, optzoom, crop },
    );
    defer allocator.free(filter);

    const argv = [_][]const u8{
        executable,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-map_metadata",
        "0",
        "-vf",
        filter,
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-movflags",
        "+faststart",
        output_path,
    };
    const result = run(allocator, &argv, working_directory, error.RenderFailed) catch |err| switch (err) {
        error.FileNotFound => return error.ToolNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

pub fn parseProbeOutput(output: []const u8) CliError!ProbeInfo {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var rate_numerator: ?u32 = null;
    var rate_denominator: ?u32 = null;
    var duration: ?f64 = null;
    var frame_count: ?u64 = null;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..separator];
        const value = line[separator + 1 ..];

        if (std.mem.eql(u8, key, "width")) {
            width = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidProbeOutput;
        } else if (std.mem.eql(u8, key, "height")) {
            height = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidProbeOutput;
        } else if (std.mem.eql(u8, key, "avg_frame_rate")) {
            const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidProbeOutput;
            rate_numerator = std.fmt.parseUnsigned(u32, value[0..slash], 10) catch return error.InvalidProbeOutput;
            rate_denominator = std.fmt.parseUnsigned(u32, value[slash + 1 ..], 10) catch return error.InvalidProbeOutput;
        } else if (std.mem.eql(u8, key, "duration") and !std.mem.eql(u8, value, "N/A")) {
            duration = std.fmt.parseFloat(f64, value) catch return error.InvalidProbeOutput;
        } else if (std.mem.eql(u8, key, "nb_frames") and !std.mem.eql(u8, value, "N/A")) {
            frame_count = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidProbeOutput;
        }
    }

    const denominator = rate_denominator orelse return error.InvalidProbeOutput;
    if (denominator == 0) return error.InvalidFrameRate;
    const duration_seconds = duration orelse return error.InvalidProbeOutput;
    if (!std.math.isFinite(duration_seconds) or duration_seconds <= 0) return error.InvalidProbeOutput;

    return .{
        .width = width orelse return error.InvalidProbeOutput,
        .height = height orelse return error.InvalidProbeOutput,
        .frame_rate_numerator = rate_numerator orelse return error.InvalidProbeOutput,
        .frame_rate_denominator = denominator,
        .duration_seconds = duration_seconds,
        .frame_count = frame_count,
    };
}

fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    failure: CliError,
) !std.process.Child.RunResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = working_directory,
        .max_output_bytes = 2 * 1024 * 1024,
        .expand_arg0 = .expand,
    });
    const success = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        std.log.err("external media command failed ({s}): {s}", .{ @errorName(failure), result.stderr });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return failure;
    }
    return result;
}
