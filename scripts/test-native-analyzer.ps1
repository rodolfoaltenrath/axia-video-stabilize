param(
    [string]$FfmpegRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\ffmpeg-8.1-shared",
    [string]$OpenCvRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\opencv-4.13.0-zig"
)

$ErrorActionPreference = "Stop"

$ffmpegInclude = Join-Path $FfmpegRoot "include"
$ffmpegLibrary = Join-Path $FfmpegRoot "lib"
$ffmpegBinary = Join-Path $FfmpegRoot "bin"
$opencvInclude = Join-Path $OpenCvRoot "include"
$opencvLibrary = Join-Path $OpenCvRoot "x64\mingw\lib"
$opencvBinary = Join-Path $OpenCvRoot "x64\mingw\bin"

foreach ($requiredPath in @(
    $ffmpegInclude,
    $ffmpegLibrary,
    $ffmpegBinary,
    $opencvInclude,
    $opencvLibrary,
    $opencvBinary
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Dependência nativa não encontrada: $requiredPath"
    }
}

$ffmpeg = Join-Path $ffmpegBinary "ffmpeg.exe"
$originalPath = $env:PATH
$env:PATH = $ffmpegBinary + [IO.Path]::PathSeparator +
    $opencvBinary + [IO.Path]::PathSeparator + $originalPath
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) (
    "axia-native-analyzer-" + [Guid]::NewGuid().ToString("N")
)
$fixture = Join-Path $testDirectory "translation-18.mp4"
New-Item -ItemType Directory -Path $testDirectory | Out-Null

try {
    & $ffmpeg `
        -hide_banner -loglevel error -y `
        -f lavfi -i "testsrc2=size=320x180:rate=18" `
        -f lavfi -i "sine=frequency=880:sample_rate=48000" `
        -frames:v 18 -shortest `
        -c:v libx264 -pix_fmt yuv420p -c:a aac `
        $fixture
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível gerar a fixture do Analyzer."
    }

    & zig build test `
        -Dnative-ffmpeg=true `
        -Dnative-opencv=true `
        "-Dffmpeg-include=$ffmpegInclude" `
        "-Dffmpeg-lib=$ffmpegLibrary" `
        "-Dopencv-include=$opencvInclude" `
        "-Dopencv-lib=$opencvLibrary" `
        "-Dtest-video=$fixture" `
        -Dtest-video-frames=18 `
        -Dtest-video-audio-streams=1 `
        --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "Os testes do Analyzer nativo falharam."
    }
} finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDirectory -ErrorAction SilentlyContinue
}
