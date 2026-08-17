# Axia Video Stabilize

Desktop video-stabilization application and CLI for Windows and Linux, written
in Zig and backed by a native automatic stabilization pipeline.

The project has a single stabilization engine, implemented in `src/engine`.
It provides frame-exact
FFmpeg decoding, presentation timestamps for CFR/VFR media, spatially
distributed Shi-Tomasi features, forward/backward pyramidal Lucas-Kanade
tracking, RANSAC similarity transforms, scene segmentation and
confidence-weighted, timestamp-aware trajectory smoothing. It also builds a
per-scene static or dynamic crop plan, decodes full-resolution BGRA frames,
warps them through reusable buffers, encodes H.264 and remuxes the source audio
and metadata into a transactionally published MP4.

PQ/HDR10 and HLG inputs are converted from BT.2020 to SDR BT.709 through a
16-bit, highlight-preserving tone-mapping path before stabilization and H.264
encoding. SDR inputs retain their original color metadata.

## Requirements

- Zig 0.13.0
- FFmpeg development libraries, including avcodec, avformat, avutil and swscale
- OpenCV development libraries used by the small bridge in `native/`
- The `ffmpeg` executable on `PATH` for the graphical video preview,
  non-AAC audio conversion and test fixture generation
- On Fedora, `libavcodec-freeworld` from RPM Fusion is required for codecs
  omitted by `ffmpeg-free`, including HEVC/H.265
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

The current release candidate version is read from `build.zig.zon` and embedded
in both executables. Check it without starting the graphical application:

```text
zig build cli -- --version
```

When custom native library directories are supplied, the `run`, `cli` and
`test` build steps configure their runtime environment automatically. Use
these steps for development; the Fedora archive has launchers for direct use.

### Fedora release package

Generate an optimized, reproducible archive containing the application, CLI
and the non-system shared libraries used by the build:

```text
AXIA_DEPS_ROOT="$HOME/.local/share/axia-deps/fc44/root/usr" \
  ./scripts/package-linux.sh
```

The archive and its SHA-256 checksum are written to `dist/`. Extract it and run
`./axia-video-stabilize`; its launcher configures the bundled libraries, so a
global `libflexiblas` installation is not required. The target Fedora system
still needs `ffmpeg` for preview and non-AAC audio conversion, plus `zenity` or
`kdialog` for the file selector.

### Windows release package

On a Windows x86_64 development machine with the native dependency roots used
by the test scripts, generate the self-contained ZIP with:

```text
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1
```

The ZIP includes both Axia executables, FFmpeg/FFprobe, the required FFmpeg and
OpenCV DLLs, third-party licenses and a SHA-256 checksum. Preview and non-AAC
audio conversion automatically prefer the bundled `ffmpeg.exe`; setting
`AXIA_FFMPEG` still overrides it for development and troubleshooting.

After starting the application, select **Importar vídeo** and choose a supported
file. Axia will analyze the clip frame by frame, report live frame progress and
export `<input-name>-stabilized.mp4` beside the original. If that name already
exists, the graphical application and CLI with automatic output naming select
`-stabilized-2`, `-3` and so on, preserving every previous export. An explicit
CLI output path remains under the caller's control.

You can also drag one video directly onto the application window or open it as
the graphical executable's only argument. During development:

```text
zig build run -- /path/to/input.mp4
```

The workspace includes a real video preview with compact play/pause, ±5-second
skip controls, space-bar control and a seek bar below the image. FFmpeg streams
at most 960x540 and 30 fps with one RGBA frame ahead into a proportional Raylib
texture, respecting display rotation while keeping memory bounded regardless
of the source duration. Preview throttling does not change the export frame
rate.

The graphical workspace offers three H.264 export-quality profiles: **Alta**
prioritizes image quality, **Padrão** keeps the engine defaults and **Leve**
trades some fidelity for a smaller, faster export. During processing, the
timeline distinguishes analysis, trajectory smoothing, rendering and final
muxing, and reports measured frames per second with an ETA when enough samples
are available. The application opens maximized to match the monitor's available
workspace and remains resizable through the native window controls.

FFmpeg and OpenCV are enabled by default when installed in standard system
locations:

```text
zig build run
```

On Fedora, the build also discovers dependency bundles stored under
`~/.local/share/axia-deps`, including the bundle used by the release packaging
script. Set `AXIA_DEPS_ROOT` to the bundle's `usr` directory to select a
different location explicitly.

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

To generate a frame-by-frame diagnostic report alongside the export:

```text
zig build cli -- input.mp4 output.mp4 --diagnostics diagnostics.csv
```

The CSV includes tracking confidence, detected/tracked/inlier point counts,
residual and spatial coverage, scene/fallback flags, measured motion, raw and
smoothed trajectories, final correction and crop/zoom limits. The report is
optional and is written transactionally, so an interrupted write does not
publish a partial CSV.

There is no legacy backend or backend selection flag. AAC source tracks are
copied without recompression. Other source audio codecs, including Opus and
Vorbis, are converted to AAC during the final mux so the resulting MP4 remains
compatible with common players. All mapped audio tracks and source metadata are
preserved; set `AXIA_FFMPEG` when the executable is not available on `PATH`.

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
