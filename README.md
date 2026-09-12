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

The first editor foundation now lives in `src/editor` and `src/effects`. It
adds rational timeline time, non-destructive clips and a typed stabilization
effect while preserving the current application and CLI. See
[`docs/EDITOR_ROADMAP.md`](docs/EDITOR_ROADMAP.md) for the migration milestones.
The desktop workspace presents the imported video as a selected timeline clip
and exposes stabilization through its effect inspector.

PQ/HDR10 and HLG inputs are converted from BT.2020 to SDR BT.709 through a
16-bit, highlight-preserving tone-mapping path before stabilization and H.264
encoding. SDR inputs retain their original color metadata.

## Requirements

- Zig 0.13.0 (the project is not yet compatible with Zig 0.16)
- FFmpeg development libraries, including avcodec, avformat, avutil and swscale
- OpenCV development libraries used by the small bridge in `native/`
- The `ffmpeg` executable on `PATH` for the graphical video preview,
  non-AAC audio conversion and test fixture generation
- On Fedora, `libavcodec-freeworld` from RPM Fusion is required for codecs
  omitted by `ffmpeg-free`, including HEVC/H.265
- On Linux, `zenity` (GNOME and most Fedora installations) or `kdialog` (KDE)
  for the graphical video file selector
- Windows 10/11 or Linux with the usual X11/OpenGL development packages

On Fedora with RPM Fusion FFmpeg installed, prepare a development machine with:

```text
sudo dnf install gcc-c++ ffmpeg-devel opencv-devel \
  libX11-devel libXcursor-devel libXext-devel libXfixes-devel \
  libXi-devel libXinerama-devel libXrandr-devel libXrender-devel \
  mesa-libGL-devel
```

Use `ffmpeg-free-devel` in place of `ffmpeg-devel` only when the system uses
Fedora's `ffmpeg-free` packages instead of RPM Fusion FFmpeg.

Raylib 5.5 is downloaded and compiled by Zig. It creates the OpenGL 3.3 window
and keeps the repository independent from a global GUI installation.
Montserrat Regular and SemiBold are embedded in the executable. Their OFL 1.1
license is included in `src/assets/fonts/OFL.txt`.

## Build and run

```text
./zigw build run
./zigw build -Doptimize=ReleaseFast
./zigw build test
```

The current release candidate version is read from `build.zig.zon` and embedded
in both executables. Check it without starting the graphical application:

```text
./zigw build cli -- --version
```

`zigw` selects Zig 0.13.0 without replacing a newer system Zig. It checks
`AXIA_ZIG`, `.tools/zig`, the adjacent development toolchain and finally
`PATH`, and reports a clear version error when none is compatible.

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
./zigw build run -- /path/to/input.mp4
```

The workspace includes a real video preview with compact play/pause, ±5-second
skip controls, space-bar control and a seek bar below the image. FFmpeg streams
one RGBA frame ahead into a proportional Raylib texture, respecting display
rotation while keeping memory bounded regardless of the source duration.
Sources with a high decoding cost use an orientation-aware 960x540 landscape
or 540x960 portrait preview at 24 fps. The decision considers resolution,
frame rate, encoded bitrate and HDR rather
than resolution alone. Lighter sources remain capped at 960x540 and 30 fps.
For demanding sources, Axia keeps the first decoded frame as a poster and
builds a video-only H.264 proxy in the user's cache. HDR proxies are tone
mapped to SDR BT.709. The monitor switches to the proxy automatically when it
is ready, and later imports reuse the cached file. Proxy creation never changes
the project source used by stabilization or export.
Decoding uses FFmpeg's automatic codec threading and attempts available
hardware acceleration with a transparent software fallback. Preview resolution
and throttling never change analysis or export, which continue to consume the
original media.

Set `AXIA_PREVIEW_DIAGNOSTICS=1` when launching the graphical application to
show preview pipeline and GPU-upload timing in the monitor.

The graphical workspace offers three H.264 export-quality profiles: **Alta**
prioritizes image quality, **Padrão** keeps the engine defaults and **Leve**
trades some fidelity for a smaller, faster export. During processing, the
timeline distinguishes analysis, trajectory smoothing, rendering and final
muxing, and reports measured frames per second with an ETA when enough samples
are available. The application opens maximized to match the monitor's available
workspace and remains resizable through the native window controls.

Stabilization can be disabled in the clip inspector. In that mode Axia skips
motion analysis and video re-encoding, remuxes the original video losslessly
to an `-export.mp4` output and preserves compatible audio and metadata.

FFmpeg and OpenCV are enabled by default when installed in standard system
locations:

```text
./zigw build run
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
./zigw build cli -- input.mp4 output.mp4
```

To generate a frame-by-frame diagnostic report alongside the export:

```text
./zigw build cli -- input.mp4 output.mp4 --diagnostics diagnostics.csv
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
