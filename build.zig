const std = @import("std");
const raylib_zig = @import("raylib_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // FFmpeg/OpenCV are optional while the UI and pipeline skeleton are being
    // developed. Enable them with -Dnative-video=true once their development
    // libraries are installed on the host or in the supplied search paths.
    const native_video = b.option(bool, "native-video", "Link FFmpeg and OpenCV C APIs") orelse false;
    const native_include = b.option([]const u8, "native-include", "Directory containing FFmpeg/OpenCV headers");
    const native_lib = b.option([]const u8, "native-lib", "Directory containing FFmpeg/OpenCV libraries");

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
    build_options.addOption(bool, "native_video", native_video);
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
    exe.linkLibrary(raylib_dep.artifact("raylib"));
    exe.linkLibC();

    if (native_video) {
        if (native_include) |path| exe.addIncludePath(.{ .cwd_relative = path });
        if (native_lib) |path| exe.addLibraryPath(.{ .cwd_relative = path });

        exe.linkSystemLibrary("avcodec");
        exe.linkSystemLibrary("avformat");
        exe.linkSystemLibrary("avutil");
        exe.linkSystemLibrary("swscale");
        exe.linkSystemLibrary("opencv_core");
        exe.linkSystemLibrary("opencv_imgproc");
        exe.linkSystemLibrary("opencv_video");
        exe.linkSystemLibrary("opencv_calib3d");
    }

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
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
