# Axia Video Stabilize

Desktop video-stabilization workspace for Windows and Linux, written in Zig.
The project is evolving from a responsive UI prototype into a real automatic
stabilization pipeline.

The project has a single stabilization engine, implemented in `src/engine`.
It provides frame-exact
FFmpeg decoding, presentation timestamps for CFR/VFR media, spatially
distributed Shi-Tomasi features, forward/backward pyramidal Lucas-Kanade
tracking, RANSAC similarity transforms, scene segmentation and
confidence-weighted, timestamp-aware trajectory smoothing. It also builds a
per-scene static or dynamic crop plan, decodes full-resolution BGRA frames,
warps them through reusable buffers, encodes H.264 and remuxes the source audio
and metadata into a transactionally published MP4.

## Requirements

- Zig 0.13.0
- FFmpeg development libraries, including avcodec, avformat, avutil and swscale
- OpenCV development libraries used by the small bridge in `native/`
- The `ffmpeg` executable on `PATH` for the graphical video preview and test
  fixture generation
- On Linux, `zenity` (GNOME and most Fedora installations) or `kdialog` (KDE)
  for the graphical video file selector
- Windows 10/11 or Linux with the usual X11/OpenGL development packages

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

The workspace includes a real video preview with compact play/pause, ±5-second
skip controls, space-bar control and a seek bar below the image. FFmpeg streams
at most 960x540 and 60 fps with one RGBA frame ahead into a reusable Raylib
texture, keeping memory bounded regardless of the source duration.

FFmpeg and OpenCV are enabled by default when installed in standard system
locations:

```text
zig build run
```

On Windows, custom library locations can be supplied explicitly:

```text
zig build run \
  -Dnative-include=C:/deps/include \
  -Dnative-lib=C:/deps/lib
```

The same pipeline is also available without the graphical window:

```text
zig build cli -- input.mp4 output.mp4
```

There is no legacy backend or backend selection flag. Export currently stream
copies source audio tracks into MP4; inputs whose audio codec is not accepted by
the MP4 muxer fail explicitly instead of losing audio.

Run the reproducible end-to-end smoke test on Windows:

```text
powershell -ExecutionPolicy Bypass -File scripts/smoke-test.ps1
```

Integration tests are split by dependency and can be run with:

```text
powershell -ExecutionPolicy Bypass -File scripts/test-native-decoder.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-features.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-analyzer.ps1
```
