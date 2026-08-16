const std = @import("std");
const raylib_zig = @import("raylib_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = packageVersion(b);
    const semantic_version = std.SemanticVersion.parse(app_version) catch
        @panic("build.zig.zon contains an invalid semantic version");

    // The native engine is the product engine and its dependencies are enabled
    // by default. Granular switches exist for focused adapter tests.
    const native_video = b.option(bool, "native-video", "Link FFmpeg and OpenCV C APIs") orelse true;
    const native_ffmpeg = b.option(bool, "native-ffmpeg", "Link the FFmpeg C API") orelse native_video;
    const native_opencv = b.option(bool, "native-opencv", "Link the OpenCV bridge") orelse native_video;
    const native_include = b.option([]const u8, "native-include", "Directory containing FFmpeg/OpenCV headers");
    const native_lib = b.option([]const u8, "native-lib", "Directory containing FFmpeg/OpenCV libraries");
    const ffmpeg_include_option = b.option([]const u8, "ffmpeg-include", "Directory containing FFmpeg headers");
    const ffmpeg_lib_option = b.option([]const u8, "ffmpeg-lib", "Directory containing FFmpeg libraries");
    const opencv_include_option = b.option([]const u8, "opencv-include", "Directory containing OpenCV headers");
    const opencv_lib_option = b.option([]const u8, "opencv-lib", "Directory containing OpenCV libraries");
    const installed_ffmpeg = installedDependencyRoot(b, target.result.os.tag, "ffmpeg-8.1-shared");
    const installed_opencv = installedDependencyRoot(b, target.result.os.tag, "opencv-4.13.0-zig");
    const ffmpeg_include = ffmpeg_include_option orelse native_include orelse dependencySubdirectory(b, installed_ffmpeg, "include");
    const ffmpeg_lib = ffmpeg_lib_option orelse native_lib orelse dependencySubdirectory(b, installed_ffmpeg, "lib");
    const opencv_include = opencv_include_option orelse native_include orelse dependencySubdirectory(b, installed_opencv, "include");
    const opencv_lib = opencv_lib_option orelse native_lib orelse dependencySubdirectory(b, installed_opencv, "x64/mingw/lib");
    const test_video = b.option([]const u8, "test-video", "Video fixture for native decoder tests") orelse "";
    const test_video_frames = b.option(u64, "test-video-frames", "Expected decoded fixture frame count") orelse 0;
    const test_video_audio_streams = b.option(u32, "test-video-audio-streams", "Expected audio streams in the native fixture") orelse 0;
    const test_video_require_vfr = b.option(bool, "test-video-require-vfr", "Require varying fixture PTS deltas") orelse false;
    const opencv_bridge = b.path("native/opencv_bridge.cpp");
    const bridge_include = b.path("native");
    const linux_opencv_bridge = if (native_opencv and target.result.os.tag == .linux)
        buildLinuxOpenCvBridge(
            b,
            opencv_bridge,
            bridge_include,
            opencv_include,
        )
    else
        null;

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .raudio = false,
        .rmodels = false,
        .opengl_version = raylib_zig.OpenglVersion.gl_3_3,
    });

    const exe = b.addExecutable(.{
        .name = "axia-video-stabilize",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .version = semantic_version,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption(bool, "native_ffmpeg", native_ffmpeg);
    build_options.addOption(bool, "native_opencv", native_opencv);
    build_options.addOption([]const u8, "test_video", test_video);
    build_options.addOption(u64, "test_video_frames", test_video_frames);
    build_options.addOption(u32, "test_video_audio_streams", test_video_audio_streams);
    build_options.addOption(bool, "test_video_require_vfr", test_video_require_vfr);
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
    exe.linkLibrary(raylib_dep.artifact("raylib"));
    exe.linkLibC();
    linkNativeDependencies(
        b,
        exe,
        native_ffmpeg,
        native_opencv,
        ffmpeg_include,
        ffmpeg_lib,
        opencv_include,
        opencv_lib,
        target.result.os.tag,
        opencv_bridge,
        bridge_include,
        linux_opencv_bridge,
    );

    // raylib links the platform windowing dependencies. These explicit OpenGL
    // links document and enforce the desktop renderer requested by the app.
    switch (target.result.os.tag) {
        .windows => {
            exe.linkSystemLibrary("opengl32");
            exe.linkSystemLibrary("comdlg32");
        },
        .linux => {
            exe.linkSystemLibrary("GL");
            exe.linkSystemLibrary("pthread");
            exe.linkSystemLibrary("dl");
        },
        else => {},
    }

    b.installArtifact(exe);

    const cli = b.addExecutable(.{
        .name = "axia-cli",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .version = semantic_version,
    });
    cli.root_module.addOptions("build_options", build_options);
    cli.linkLibC();
    linkNativeDependencies(
        b,
        cli,
        native_ffmpeg,
        native_opencv,
        ffmpeg_include,
        ffmpeg_lib,
        opencv_include,
        opencv_lib,
        target.result.os.tag,
        opencv_bridge,
        bridge_include,
        linux_opencv_bridge,
    );
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    configureLinuxRuntime(b, run_cmd, target.result.os.tag, ffmpeg_lib, opencv_lib);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Zig Stabilizer");
    run_step.dependOn(&run_cmd.step);

    const cli_cmd = b.addRunArtifact(cli);
    configureLinuxRuntime(b, cli_cmd, target.result.os.tag, ffmpeg_lib, opencv_lib);
    if (b.args) |args| cli_cmd.addArgs(args);
    const cli_step = b.step("cli", "Run the headless stabilization pipeline");
    cli_step.dependOn(&cli_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("build_options", build_options);
    unit_tests.linkLibC();
    linkNativeDependencies(
        b,
        unit_tests,
        native_ffmpeg,
        native_opencv,
        ffmpeg_include,
        ffmpeg_lib,
        opencv_include,
        opencv_lib,
        target.result.os.tag,
        opencv_bridge,
        bridge_include,
        linux_opencv_bridge,
    );
    const run_tests = b.addRunArtifact(unit_tests);
    configureLinuxRuntime(b, run_tests, target.result.os.tag, ffmpeg_lib, opencv_lib);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn packageVersion(b: *std.Build) []const u8 {
    const manifest = b.build_root.handle.readFileAlloc(
        b.allocator,
        "build.zig.zon",
        64 * 1024,
    ) catch @panic("could not read build.zig.zon");
    const marker = ".version = \"";
    const marker_index = std.mem.indexOf(u8, manifest, marker) orelse
        @panic("build.zig.zon does not declare a version");
    const version_start = marker_index + marker.len;
    const version_end_relative = std.mem.indexOfScalar(
        u8,
        manifest[version_start..],
        '\"',
    ) orelse @panic("build.zig.zon contains an unterminated version");
    return b.dupe(manifest[version_start .. version_start + version_end_relative]);
}

fn installedDependencyRoot(
    b: *std.Build,
    target_os: std.Target.Os.Tag,
    directory: []const u8,
) ?[]const u8 {
    if (target_os != .windows) return null;

    const local_app_data = std.process.getEnvVarOwned(b.allocator, "LOCALAPPDATA") catch return null;
    const root = b.pathJoin(&.{ local_app_data, "Programs", "AxiaDeps", directory });
    std.fs.accessAbsolute(root, .{}) catch return null;
    return root;
}

fn dependencySubdirectory(
    b: *std.Build,
    root: ?[]const u8,
    subdirectory: []const u8,
) ?[]const u8 {
    const path = root orelse return null;
    return b.pathJoin(&.{ path, subdirectory });
}

fn linkNativeDependencies(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    native_ffmpeg: bool,
    native_opencv: bool,
    ffmpeg_include: ?[]const u8,
    ffmpeg_lib: ?[]const u8,
    opencv_include: ?[]const u8,
    opencv_lib: ?[]const u8,
    target_os: std.Target.Os.Tag,
    opencv_bridge: std.Build.LazyPath,
    bridge_include: std.Build.LazyPath,
    linux_opencv_bridge: ?std.Build.LazyPath,
) void {
    if (native_ffmpeg) {
        if (ffmpeg_include) |path| artifact.addIncludePath(.{ .cwd_relative = path });
        if (ffmpeg_lib) |path| artifact.addLibraryPath(.{ .cwd_relative = path });
        artifact.linkSystemLibrary("avcodec");
        artifact.linkSystemLibrary("avformat");
        artifact.linkSystemLibrary("avutil");
        artifact.linkSystemLibrary("swscale");
    }

    if (native_opencv) {
        if (opencv_include) |path| artifact.addIncludePath(.{ .cwd_relative = path });
        artifact.addIncludePath(bridge_include);
        if (linux_opencv_bridge) |object| {
            artifact.addObjectFile(object);
            artifact.addObjectFile(.{
                .cwd_relative = findCompilerLibrary(b, "libstdc++.so"),
            });
            artifact.addObjectFile(.{
                .cwd_relative = findCompilerLibrary(b, "libgcc_s.so"),
            });
        } else {
            artifact.addCSourceFile(.{
                .file = opencv_bridge,
                .flags = &.{ "-std=c++17", "-fexceptions" },
            });
            artifact.linkLibCpp();
        }

        if (opencv_lib) |path| {
            artifact.addLibraryPath(.{ .cwd_relative = path });
        }
        switch (target_os) {
            .windows => if (opencv_lib) |path| {
                // MinGW import libraries carry the OpenCV ABI version.
                for ([_][]const u8{
                    "libopencv_core4130.dll.a",
                    "libopencv_imgproc4130.dll.a",
                    "libopencv_video4130.dll.a",
                    "libopencv_calib3d4130.dll.a",
                }) |library| {
                    artifact.addObjectFile(.{
                        .cwd_relative = b.pathJoin(&.{ path, library }),
                    });
                }
            } else {
                artifact.linkSystemLibrary("opencv_core4130");
                artifact.linkSystemLibrary("opencv_imgproc4130");
                artifact.linkSystemLibrary("opencv_video4130");
                artifact.linkSystemLibrary("opencv_calib3d4130");
            },
            else => {
                artifact.linkSystemLibrary("opencv_core");
                artifact.linkSystemLibrary("opencv_imgproc");
                artifact.linkSystemLibrary("opencv_video");
                artifact.linkSystemLibrary("opencv_calib3d");
            },
        }
    }
}

fn configureLinuxRuntime(
    b: *std.Build,
    run: *std.Build.Step.Run,
    target_os: std.Target.Os.Tag,
    ffmpeg_lib: ?[]const u8,
    opencv_lib: ?[]const u8,
) void {
    if (target_os != .linux) return;
    const primary_path = opencv_lib orelse ffmpeg_lib orelse return;
    const native_paths = if (ffmpeg_lib) |ffmpeg_path|
        if (!std.mem.eql(u8, ffmpeg_path, primary_path))
            b.fmt("{s}:{s}", .{ primary_path, ffmpeg_path })
        else
            primary_path
    else
        primary_path;
    const inherited = b.graph.env_map.get("LD_LIBRARY_PATH");
    run.setEnvironmentVariable(
        "LD_LIBRARY_PATH",
        if (inherited) |value|
            b.fmt("{s}:{s}", .{ native_paths, value })
        else
            native_paths,
    );

    const flexiblas_path = b.pathJoin(&.{ primary_path, "flexiblas" });
    const flexiblas_backend = b.pathJoin(&.{ flexiblas_path, "libflexiblas_netlib.so" });
    std.fs.accessAbsolute(flexiblas_backend, .{}) catch return;
    run.setEnvironmentVariable("FLEXIBLAS_LIBRARY_PATH", flexiblas_path);
    run.setEnvironmentVariable("FLEXIBLAS", flexiblas_backend);
}

fn buildLinuxOpenCvBridge(
    b: *std.Build,
    source: std.Build.LazyPath,
    bridge_include: std.Build.LazyPath,
    opencv_include: ?[]const u8,
) std.Build.LazyPath {
    const compiler = b.findProgram(&.{ "c++", "g++", "clang++" }, &.{}) catch
        @panic("OpenCV on Linux requires a system C++ compiler");
    const command = b.addSystemCommand(&.{
        compiler,
        "-c",
        "-std=c++17",
        "-fPIC",
        "-fexceptions",
    });
    command.addPrefixedDirectoryArg("-I", bridge_include);
    if (opencv_include) |path| {
        command.addArg(b.fmt("-I{s}", .{path}));
    }
    command.addFileArg(source);
    command.addArg("-o");
    return command.addOutputFileArg("opencv_bridge.o");
}

fn findCompilerLibrary(b: *std.Build, library: []const u8) []const u8 {
    const compiler = b.findProgram(&.{ "c++", "g++", "clang++" }, &.{}) catch
        @panic("OpenCV on Linux requires a system C++ compiler");
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ compiler, b.fmt("-print-file-name={s}", .{library}) },
        .env_map = &b.graph.env_map,
    }) catch @panic("could not locate libstdc++");
    if (result.term != .Exited or result.term.Exited != 0) {
        @panic("could not locate libstdc++");
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0 or std.mem.eql(u8, path, library)) {
        @panic("system C++ compiler did not report a required runtime library");
    }
    return b.dupe(path);
}
