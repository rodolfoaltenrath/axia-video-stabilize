# Axia Video Stabilize

[English](#english) · [Português](#português)

---

<a id="english"></a>

## English

Desktop application and CLI for automatic video stabilization on Windows and
Linux, written in Zig and powered by a native FFmpeg/OpenCV pipeline.

### Features

- Frame-accurate FFmpeg decoding with presentation timestamps for CFR and VFR media.
- Spatially distributed Shi-Tomasi features, forward/backward pyramidal
  Lucas-Kanade tracking, RANSAC similarity transforms, scene segmentation, and
  confidence-weighted, timestamp-aware trajectory smoothing.
- Per-scene static or dynamic crop planning and full-resolution BGRA rendering
  through reusable buffers.
- H.264 encoding with transactional publication and source audio tracks and
  metadata preserved whenever they are compatible with MP4.
- HDR10/PQ and HLG conversion from BT.2020 to SDR BT.709 through a 16-bit,
  highlight-preserving tone-mapping path. SDR color metadata is retained.
- Rational timeline time, non-destructive clips, and typed stabilization effects.
- Graphical playback, seeking, automatic proxies, and three export-quality profiles.

The shared stabilization engine lives in `src/engine`; editor and effect models
live in `src/editor` and `src/effects`. The desktop workspace represents an
imported video as a selected timeline clip and exposes stabilization through
the effect inspector. The GUI and CLI use the same processing pipeline.

### Requirements

- Zig 0.16.0.
- FFmpeg development libraries: `avcodec`, `avformat`, `avutil`, and `swscale`.
- OpenCV development libraries for the bridge in `native/`.
- The `ffmpeg` executable on `PATH` for graphical preview, non-AAC audio
  conversion, and test-fixture generation.
- On Fedora, `libavcodec-freeworld` from RPM Fusion for codecs omitted from
  `ffmpeg-free`, including HEVC/H.265.
- On Linux, `zenity` (GNOME/Fedora) or `kdialog` (KDE) for the file picker.
- Windows 10/11, or Linux with the usual X11/OpenGL development packages.

Fedora setup with RPM Fusion FFmpeg:

```bash
sudo dnf install gcc-c++ ffmpeg-devel opencv-devel \
  libX11-devel libXcursor-devel libXext-devel libXfixes-devel \
  libXi-devel libXinerama-devel libXrandr-devel libXrender-devel \
  mesa-libGL-devel
```

Use `ffmpeg-free-devel` instead of `ffmpeg-devel` only when using Fedora's
`ffmpeg-free` packages. Raylib 6.0 bindings are downloaded and compiled by Zig,
so no global GUI installation is required. Montserrat Regular and SemiBold are
embedded; their OFL 1.1 license is in `src/assets/fonts/OFL.txt`.

### Build and run

```bash
./zigw build run
./zigw build -Doptimize=ReleaseFast
./zigw build test
```

The release-candidate version comes from `build.zig.zon` and is embedded in both
executables. Check it without opening the GUI:

```bash
./zigw build cli -- --version
```

`zigw` selects Zig 0.16.0 without replacing another installation. It checks
`AXIA_ZIG`, `.tools/zig`, the adjacent development toolchain, and then `PATH`,
reporting a clear error if no compatible version is found. When custom native
library directories are supplied, the `run`, `cli`, and `test` steps configure
their runtime environment automatically.

### Desktop application

Start Axia and select **Importar mídia** (the current UI uses Portuguese labels)
to choose a supported video. Axia analyzes it frame by frame, shows live
progress, and writes `<input-name>-stabilized.mp4` beside the source. If that
name exists, it uses `-stabilized-2`, `-stabilized-3`, and so on. An explicit
CLI output path remains under the caller's control.

You may also drag one video onto the window or pass it as the graphical
executable's only argument:

```bash
./zigw build run -- /path/to/input.mp4
```

#### Preview and proxies

The workspace provides play/pause, ±5-second controls, space-bar playback, and
a seek bar. FFmpeg streams one RGBA frame ahead into a proportional Raylib
texture, respects display rotation, and keeps memory bounded regardless of
duration. Preview selection considers resolution, frame rate, bitrate, and HDR:

- Lighter sources are capped at 960×540 and 30 fps.
- Demanding sources use 960×540 landscape or 540×960 portrait at 24 fps.
- Axia keeps the first frame as a poster while generating a video-only H.264
  proxy in the user's cache; later imports reuse it.
- HDR proxies are tone-mapped to SDR BT.709 at an intermediate 1.5× resolution.

Proxy workers size decoder, filter, and encoder thread counts from available
CPUs. The monitor switches to the proxy automatically. Proxies never change the
source used for analysis or export. FFmpeg automatic codec threading tries
available hardware acceleration with transparent software fallback. Preview
resolution and throttling never affect the full-quality export.

Show preview-pipeline and GPU-upload timings with:

```bash
AXIA_PREVIEW_DIAGNOSTICS=1 ./zigw build run
```

#### Export

The GUI offers three H.264 profiles:

- **Alta** prioritizes quality and uses cubic affine interpolation.
- **Padrão** keeps engine defaults and uses linear interpolation.
- **Leve** uses linear interpolation for a smaller, faster export.

The timeline distinguishes analysis, trajectory smoothing, rendering, and final
muxing, reporting measured fps and an ETA when enough samples exist. HDR export
uses FFmpeg Mobius tone mapping, matching the preview, and attempts hardware
decoding with software fallback. Decoding the next frame overlaps stabilization
and encoding of the current frame via reusable buffers, avoiding high-resolution
copies between stages. The application opens maximized and remains resizable.

Stabilization can be disabled in the clip inspector. Axia then skips motion
analysis and video re-encoding, losslessly remuxes the source to `-export.mp4`,
and preserves compatible audio and metadata.

### Native library paths

FFmpeg and OpenCV are enabled automatically in standard system locations. On
Fedora, bundles under `~/.local/share/axia-deps` are also discovered. Set
`AXIA_DEPS_ROOT` to a bundle's `usr` directory to select it explicitly.

On Windows, custom paths can be provided with:

```powershell
zig build run `
  -Dnative-include=C:/deps/include `
  -Dnative-lib=C:/deps/lib
```

### Command-line interface

```bash
./zigw build cli -- input.mp4 output.mp4
./zigw build cli -- input.mp4
./zigw build cli -- --help
./zigw build cli -- --version
```

The output is optional; when omitted, Axia chooses an available
`-stabilized.mp4` name. Generate a frame-by-frame report with:

```bash
./zigw build cli -- input.mp4 output.mp4 --diagnostics diagnostics.csv
```

The transactional CSV contains confidence, detected/tracked/inlier point
counts, residual error, spatial coverage, scene/fallback flags, measured motion,
raw and smoothed trajectories, final correction, and crop/zoom limits. An
interrupted write never publishes a partial report.

There is no legacy backend or backend-selection flag. AAC tracks are copied;
other codecs, including Opus and Vorbis, are converted to AAC during final mux
for broad MP4 compatibility. All mapped audio tracks and source metadata are
preserved. Set `AXIA_FFMPEG` to override an executable not available on `PATH`.

### Release packages

Create an optimized, reproducible Fedora archive with the application, CLI, and
non-system shared libraries:

```bash
AXIA_DEPS_ROOT="$HOME/.local/share/axia-deps/fc44/root/usr" \
  ./scripts/package-linux.sh
```

The archive and SHA-256 checksum are written to `dist/`. Extract it and run
`./axia-video-stabilize`; the launcher configures bundled libraries, so global
`libflexiblas` is unnecessary. The target still needs `ffmpeg` plus `zenity` or
`kdialog`.

On an x86_64 Windows development machine with the native dependencies used by
the test scripts, create the self-contained ZIP with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1
```

It includes both executables, FFmpeg/FFprobe, required FFmpeg/OpenCV DLLs,
third-party licenses, and a SHA-256 checksum. The bundled `ffmpeg.exe` is used
automatically unless `AXIA_FFMPEG` overrides it.

### Tests

```bash
./zigw build test
```

Windows smoke and dependency-specific integration tests:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/smoke-test.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-decoder.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-features.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-analyzer.ps1
```

[Back to language selection](#axia-video-stabilize)

---

<a id="português"></a>

## Português

Aplicativo desktop e CLI para estabilização automática de vídeos no Windows e
Linux, escrito em Zig e baseado em um pipeline nativo com FFmpeg e OpenCV.

### Recursos

- Decodificação precisa por quadro com timestamps de apresentação para mídias CFR e VFR.
- Características Shi-Tomasi distribuídas espacialmente, rastreamento
  Lucas-Kanade piramidal em ambas as direções, transformações de similaridade
  RANSAC, segmentação de cenas e suavização de trajetória ponderada por
  confiança e sensível aos timestamps.
- Planejamento de corte estático ou dinâmico por cena e renderização BGRA em
  resolução total com buffers reutilizáveis.
- Codificação H.264 com publicação transacional e preservação de áudio e
  metadados compatíveis com MP4.
- Conversão de HDR10/PQ e HLG de BT.2020 para SDR BT.709 com tone mapping de 16
  bits que preserva realces. Metadados de cor SDR são mantidos.
- Tempo racional na timeline, clipes não destrutivos e efeitos de estabilização tipados.
- Reprodução gráfica, navegação, proxies automáticos e três perfis de exportação.

O motor compartilhado está em `src/engine`; os modelos de edição e efeitos estão
em `src/editor` e `src/effects`. O workspace representa o vídeo importado como
um clipe selecionado na timeline e disponibiliza a estabilização no inspetor de
efeitos. A interface gráfica e a CLI usam o mesmo pipeline.

### Requisitos

- Zig 0.16.0.
- Bibliotecas de desenvolvimento do FFmpeg: `avcodec`, `avformat`, `avutil` e `swscale`.
- Bibliotecas de desenvolvimento do OpenCV para a ponte em `native/`.
- Executável `ffmpeg` no `PATH` para preview, conversão de áudio não AAC e fixtures.
- No Fedora, `libavcodec-freeworld` do RPM Fusion para codecs ausentes no
  `ffmpeg-free`, incluindo HEVC/H.265.
- No Linux, `zenity` (GNOME/Fedora) ou `kdialog` (KDE) para selecionar arquivos.
- Windows 10/11 ou Linux com os pacotes usuais de desenvolvimento X11/OpenGL.

Preparação do Fedora com FFmpeg do RPM Fusion:

```bash
sudo dnf install gcc-c++ ffmpeg-devel opencv-devel \
  libX11-devel libXcursor-devel libXext-devel libXfixes-devel \
  libXi-devel libXinerama-devel libXrandr-devel libXrender-devel \
  mesa-libGL-devel
```

Use `ffmpeg-free-devel` no lugar de `ffmpeg-devel` somente com os pacotes
`ffmpeg-free` do Fedora. Os bindings do Raylib 6.0 são baixados e compilados
pelo Zig, sem exigir instalação gráfica global. As fontes Montserrat Regular e
SemiBold são incorporadas; a licença OFL 1.1 está em `src/assets/fonts/OFL.txt`.

### Compilar e executar

```bash
./zigw build run
./zigw build -Doptimize=ReleaseFast
./zigw build test
```

A versão release candidate vem de `build.zig.zon` e é incorporada aos dois
executáveis. Consulte-a sem abrir a interface:

```bash
./zigw build cli -- --version
```

O `zigw` seleciona o Zig 0.16.0 sem substituir outra instalação. Ele verifica
`AXIA_ZIG`, `.tools/zig`, o toolchain adjacente e o `PATH`, apresentando um erro
claro se nenhum for compatível. Com diretórios de bibliotecas personalizados,
as etapas `run`, `cli` e `test` configuram o ambiente automaticamente.

### Aplicativo desktop

Inicie o Axia e selecione **Importar mídia**. O programa analisa o vídeo quadro
a quadro, exibe o progresso e grava `<nome>-stabilized.mp4` ao lado da fonte. Se
o nome existir, utiliza `-stabilized-2`, `-stabilized-3` e assim por diante. Um
caminho explícito na CLI permanece sob controle de quem executou o comando.

Também é possível arrastar um vídeo para a janela ou passá-lo como único argumento:

```bash
./zigw build run -- /caminho/para/entrada.mp4
```

#### Preview e proxies

O workspace oferece reprodução/pausa, controles de ±5 segundos, barra de espaço
e barra de navegação. O FFmpeg mantém um quadro RGBA adiantado em uma textura
proporcional do Raylib, respeita a rotação e limita o uso de memória. A escolha
do preview considera resolução, fps, bitrate e HDR:

- Fontes leves usam até 960×540 e 30 fps.
- Fontes exigentes usam 960×540 horizontal ou 540×960 vertical a 24 fps.
- O primeiro quadro vira capa enquanto um proxy H.264, somente de vídeo, é
  gerado no cache e reutilizado em importações futuras.
- Proxies HDR recebem tone mapping para SDR BT.709 em resolução intermediária de 1,5×.

Os workers dimensionam as threads conforme as CPUs disponíveis, e o monitor
muda automaticamente para o proxy. O proxy nunca altera a fonte de análise ou
exportação. O FFmpeg tenta aceleração por hardware, com fallback transparente
para software. Resolução e limitação do preview não afetam a exportação.

Exiba tempos do pipeline e do envio à GPU com:

```bash
AXIA_PREVIEW_DIAGNOSTICS=1 ./zigw build run
```

#### Exportação

- **Alta** prioriza qualidade e usa interpolação afim cúbica.
- **Padrão** mantém os padrões do motor e usa interpolação linear.
- **Leve** usa interpolação linear para uma exportação menor e mais rápida.

A timeline diferencia análise, suavização, renderização e mux final, informando
fps e uma estimativa de tempo quando há amostras suficientes. A exportação HDR
usa tone mapping Mobius do FFmpeg, igual ao preview, e tenta decodificação por
hardware com fallback. A decodificação do próximo quadro ocorre em paralelo à
estabilização e codificação do atual, com buffers reutilizáveis e sem cópias
entre etapas. O aplicativo abre maximizado e continua redimensionável.

A estabilização pode ser desativada no inspetor. Nesse modo, o Axia ignora a
análise e a recodificação, remuxa a fonte sem perdas para `-export.mp4` e
preserva áudio e metadados compatíveis.

### Caminhos de bibliotecas nativas

FFmpeg e OpenCV são habilitados automaticamente em locais padrão. No Fedora,
pacotes em `~/.local/share/axia-deps` também são encontrados. Defina
`AXIA_DEPS_ROOT` como o diretório `usr` do pacote para selecioná-lo.

No Windows:

```powershell
zig build run `
  -Dnative-include=C:/deps/include `
  -Dnative-lib=C:/deps/lib
```

### Interface de linha de comando

```bash
./zigw build cli -- entrada.mp4 saida.mp4
./zigw build cli -- entrada.mp4
./zigw build cli -- --help
./zigw build cli -- --version
```

A saída é opcional; quando omitida, o Axia escolhe um nome `-stabilized.mp4`
disponível. Gere um relatório por quadro com:

```bash
./zigw build cli -- entrada.mp4 saida.mp4 --diagnostics diagnostico.csv
```

O CSV transacional contém confiança, quantidades de pontos detectados/rastreados/
inliers, erro residual, cobertura espacial, flags de cena/fallback, movimento,
trajetórias bruta e suavizada, correção final e limites de corte/zoom. Uma
interrupção nunca publica um relatório parcial.

Não há backend legado nem flag de seleção. Faixas AAC são copiadas; outros
codecs, incluindo Opus e Vorbis, são convertidos para AAC no mux final. Todas as
faixas mapeadas e os metadados são preservados. Use `AXIA_FFMPEG` para indicar
ou substituir um executável ausente do `PATH`.

### Pacotes de release

Gere o arquivo Fedora reproduzível e otimizado com aplicativo, CLI e bibliotecas
compartilhadas externas ao sistema:

```bash
AXIA_DEPS_ROOT="$HOME/.local/share/axia-deps/fc44/root/usr" \
  ./scripts/package-linux.sh
```

O arquivo e o SHA-256 são gravados em `dist/`. Extraia e execute
`./axia-video-stabilize`; o launcher configura as bibliotecas incluídas, sem
exigir `libflexiblas` global. O destino ainda precisa de `ffmpeg` e de `zenity`
ou `kdialog`.

Em uma máquina Windows x86_64 com as dependências dos scripts de teste:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1
```

O ZIP autocontido inclui ambos os executáveis, FFmpeg/FFprobe, DLLs necessárias,
licenças de terceiros e SHA-256. O `ffmpeg.exe` incluído é preferido, salvo
quando `AXIA_FFMPEG` o substitui.

### Testes

```bash
./zigw build test
```

Smoke test e testes de integração no Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/smoke-test.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-decoder.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-features.ps1
powershell -ExecutionPolicy Bypass -File scripts/test-native-analyzer.ps1
```

[Voltar à seleção de idioma](#axia-video-stabilize)
