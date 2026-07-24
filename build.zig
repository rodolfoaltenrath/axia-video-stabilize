const std = @import("std");
const raylib_zig = @import("raylib_zig");

const EngineBackend = enum {
    legacy,
    native,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_backend = b.option(
        EngineBackend,
        "engine",
        "Stabilization engine to use: legacy or native",
    ) orelse .legacy;

    // FFmpeg/OpenCV are optional while the UI and pipeline skeleton are being
    // developed. Enable them with -Dnative-video=true once their development
    // libraries are installed on the host or in the supplied search paths.
    const native_video = b.option(bool, "native-video", "Link FFmpeg and OpenCV C APIs") orelse false;
    const native_ffmpeg = b.option(bool, "native-ffmpeg", "Link the FFmpeg C API") orelse native_video;
    const native_opencv = b.option(bool, "native-opencv", "Link the OpenCV bridge") orelse native_video;
    const native_include = b.option([]const u8, "native-include", "Directory containing FFmpeg/OpenCV headers");
    const native_lib = b.option([]const u8, "native-lib", "Directory containing FFmpeg/OpenCV libraries");
    const ffmpeg_include_option = b.option([]const u8, "ffmpeg-include", "Directory containing FFmpeg headers");
    const ffmpeg_lib_option = b.option([]const u8, "ffmpeg-lib", "Directory containing FFmpeg libraries");
    const opencv_include_option = b.option([]const u8, "opencv-include", "Directory containing OpenCV headers");
    const opencv_lib_option = b.option([]const u8, "opencv-lib", "Directory containing OpenCV libraries");
    const ffmpeg_include = if (ffmpeg_include_option) |path| path else native_include;
    const ffmpeg_lib = if (ffmpeg_lib_option) |path| path else native_lib;
    const opencv_include = if (opencv_include_option) |path| path else native_include;
    const opencv_lib = if (opencv_lib_option) |path| path else native_lib;
    const test_video = b.option([]const u8, "test-video", "Video fixture for native decoder tests") orelse "";
    const test_video_frames = b.option(u64, "test-video-frames", "Expected decoded fixture frame count") orelse 0;
    const test_video_require_vfr = b.option(bool, "test-video-require-vfr", "Require varying fixture PTS deltas") orelse false;

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
    });

    const build_options = b.addOptions();
    build_options.addOption(EngineBackend, "engine_backend", engine_backend);
    build_options.addOption(bool, "native_video", native_video);
    build_options.addOption(bool, "native_ffmpeg", native_ffmpeg);
    build_options.addOption(bool, "native_opencv", native_opencv);
    build_options.addOption([]const u8, "test_video", test_video);
    build_options.addOption(u64, "test_video_frames", test_video_frames);
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
        b.path("native/opencv_bridge.cpp"),
        b.path("native"),
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
        b.path("native/opencv_bridge.cpp"),
        b.path("native"),
    );
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Zig Stabilizer");
    run_step.dependOn(&run_cmd.step);

    const cli_cmd = b.addRunArtifact(cli);
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
        b.path("native/opencv_bridge.cpp"),
        b.path("native"),
    );
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
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
    opencv_bridge: std.Build.LazyPath,
    bridge_include: std.Build.LazyPath,
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
        artifact.addCSourceFile(.{
            .file = opencv_bridge,
            .flags = &.{ "-std=c++17", "-fexceptions" },
        });
        artifact.linkLibCpp();

        // OpenCV's MinGW naming includes the ABI version in import libraries.
        // Keep these explicit: accidentally resolving MSVC binaries would make
        // the C++ side of the bridge ABI-incompatible with Zig.
        if (opencv_lib) |path| {
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
        }
    }
}
