# Axia Video Stabilize

Desktop video-stabilization workspace for Windows and Linux, written in Zig.
The project is evolving from a responsive UI prototype into a real automatic
stabilization pipeline.

The current implementation uses FFmpeg and libvidstab as the first functional
two-pass backend. The planned native engine contracts live in `src/core` and
will progressively replace the CLI bridge with native decoding, tracking,
trajectory optimization, rolling-shutter correction and warping.

## Requirements

- Zig 0.13.0
- FFmpeg and ffprobe on `PATH`, including the `vidstabdetect` and
  `vidstabtransform` filters
- Windows 10/11 or Linux with the usual X11/OpenGL development packages
- FFmpeg/OpenCV development libraries only when using `-Dnative-video=true`

Raylib 5.5 is downloaded and compiled by Zig. It creates the OpenGL 3.3 window
and keeps the repository independent from a global GUI installation.
Montserrat Regular and SemiBold are embedded in the executable. Their OFL 1.1
license is included in `src/assets/fonts/OFL.txt`.

## Build and run

```text
zig build run
zig build -Doptimize=ReleaseFast
zig build test
```

After starting the application, select **Importar vídeo** and choose a supported
file. Axia will analyze the clip frame by frame, report live frame progress and
export `<input-name>-stabilized.mp4` beside the original.

The workspace includes a real video preview with play/pause, space-bar control
and timeline seeking. FFmpeg streams at most 960x540 and 60 fps with one RGBA
frame ahead into a reusable Raylib texture, keeping memory bounded regardless
of the source duration.

Enable native video libraries when installed in standard system locations:

```text
zig build run -Dnative-video=true
```

On Windows, custom library locations can be supplied explicitly:

```text
zig build run -Dnative-video=true \
  -Dnative-include=C:/deps/include \
  -Dnative-lib=C:/deps/lib
```

The same pipeline is also available without the graphical window:

```text
zig build cli -- input.mp4 output.mp4
```

Run the reproducible end-to-end smoke test on Windows:

```text
powershell -ExecutionPolicy Bypass -File scripts/smoke-test.ps1
```
