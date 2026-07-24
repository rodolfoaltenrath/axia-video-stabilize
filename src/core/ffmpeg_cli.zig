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
    Cancelled,
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

    pub fn estimatedFrameCount(self: ProbeInfo) u64 {
        if (self.frame_count) |count| return count;
        return @intFromFloat(@max(1.0, @round(self.duration_seconds * self.framesPerSecond())));
    }
};

pub const Progress = struct {
    frame: u64 = 0,
    out_time_us: u64 = 0,
    speed: f64 = 0,
    finished: bool = false,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_progress: ?*const fn (?*anyopaque, Progress) void = null,
    should_cancel: ?*const fn (?*anyopaque) bool = null,

    fn report(self: Observer, progress: Progress) void {
        if (self.on_progress) |callback| callback(self.context, progress);
    }

    fn isCancelled(self: Observer) bool {
        if (self.should_cancel) |callback| return callback(self.context);
        return false;
    }
};

pub const ProgressParser = struct {
    current: Progress = .{},

    pub fn push(self: *ProgressParser, raw_line: []const u8) ?Progress {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const key = line[0..separator];
        const value = line[separator + 1 ..];

        if (std.mem.eql(u8, key, "frame")) {
            self.current.frame = std.fmt.parseUnsigned(u64, value, 10) catch self.current.frame;
        } else if (std.mem.eql(u8, key, "out_time_us")) {
            self.current.out_time_us = std.fmt.parseUnsigned(u64, value, 10) catch self.current.out_time_us;
        } else if (std.mem.eql(u8, key, "speed")) {
            const speed_text = std.mem.trimRight(u8, std.mem.trim(u8, value, " \t"), "x");
            self.current.speed = std.fmt.parseFloat(f64, speed_text) catch self.current.speed;
        } else if (std.mem.eql(u8, key, "progress")) {
            self.current.finished = std.mem.eql(u8, value, "end");
            return self.current;
        }
        return null;
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
    observer: Observer,
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
        "-stats_period",
        "0.1",
        "-progress",
        "pipe:1",
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
    runWithProgress(allocator, &argv, working_directory, error.AnalyzeFailed, observer) catch |err| switch (err) {
        error.FileNotFound => return error.ToolNotFound,
        else => return err,
    };
}

pub fn render(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    working_directory: []const u8,
    transform_file_name: []const u8,
    parameters: state_mod.Parameters,
    info: ProbeInfo,
    observer: Observer,
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
        "-stats_period",
        "0.1",
        "-progress",
        "pipe:1",
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
    runWithProgress(allocator, &argv, working_directory, error.RenderFailed, observer) catch |err| switch (err) {
        error.FileNotFound => return error.ToolNotFound,
        else => return err,
    };
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

    const numerator = rate_numerator orelse return error.InvalidProbeOutput;
    const denominator = rate_denominator orelse return error.InvalidProbeOutput;
    if (numerator == 0) return error.InvalidFrameRate;
    if (denominator == 0) return error.InvalidFrameRate;
    const duration_seconds = duration orelse return error.InvalidProbeOutput;
    if (!std.math.isFinite(duration_seconds) or duration_seconds <= 0) return error.InvalidProbeOutput;

    return .{
        .width = width orelse return error.InvalidProbeOutput,
        .height = height orelse return error.InvalidProbeOutput,
        .frame_rate_numerator = numerator,
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

fn runWithProgress(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    failure: CliError,
    observer: Observer,
) !void {
    if (observer.isCancelled()) return error.Cancelled;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.cwd = working_directory;
    child.expand_arg0 = .expand;
    try child.spawn();

    var terminated = false;
    errdefer {
        if (!terminated) {
            _ = child.kill() catch {};
        }
    }

    var parser = ProgressParser{};
    var line_buffer: [512]u8 = undefined;
    const stdout = child.stdout orelse return failure;
    var reader = stdout.reader();
    while (try reader.readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
        if (observer.isCancelled()) {
            _ = try child.kill();
            terminated = true;
            return error.Cancelled;
        }
        if (parser.push(line)) |progress| observer.report(progress);
    }

    const term = try child.wait();
    terminated = true;
    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!success) return failure;
}
