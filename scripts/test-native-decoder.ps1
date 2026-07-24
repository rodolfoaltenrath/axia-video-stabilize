param(
    [string]$FfmpegRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\ffmpeg-8.1-shared"
)

$ErrorActionPreference = "Stop"

$includePath = Join-Path $FfmpegRoot "include"
$libraryPath = Join-Path $FfmpegRoot "lib"
$binaryPath = Join-Path $FfmpegRoot "bin"

foreach ($requiredPath in @($includePath, $libraryPath, $binaryPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Dependência FFmpeg não encontrada: $requiredPath"
    }
}

$ffmpeg = Join-Path $binaryPath "ffmpeg.exe"
$ffprobe = Join-Path $binaryPath "ffprobe.exe"
$originalPath = $env:PATH
$env:PATH = $binaryPath + [IO.Path]::PathSeparator + $originalPath
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $temporaryRoot ("axia-native-decoder-" + [Guid]::NewGuid().ToString("N"))
$cfrFixture = Join-Path $testDirectory "cfr-12.mp4"
$vfrFixture = Join-Path $testDirectory "vfr-8.mkv"

New-Item -ItemType Directory -Path $testDirectory | Out-Null

function Invoke-ZigDecoderTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Fixture,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedFrames,
        [switch]$RequireVfr
    )

    $arguments = @(
        "build",
        "test",
        "-Dnative-ffmpeg=true",
        "-Dffmpeg-include=$includePath",
        "-Dffmpeg-lib=$libraryPath",
        "-Dtest-video=$Fixture",
        "-Dtest-video-frames=$ExpectedFrames",
        "--summary",
        "all"
    )
    if ($RequireVfr) {
        $arguments += "-Dtest-video-require-vfr=true"
    }

    & zig @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Os testes do decoder falharam para $Fixture"
    }
}

try {
    & $ffmpeg `
        -hide_banner -loglevel error -y `
        -f lavfi -i "testsrc2=size=320x180:rate=12" `
        -frames:v 12 -c:v libx264 -pix_fmt yuv420p `
        $cfrFixture
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível gerar a fixture CFR."
    }
    Invoke-ZigDecoderTest -Fixture $cfrFixture -ExpectedFrames 12

    & $ffmpeg `
        -hide_banner -loglevel error -y `
        -f lavfi -t 0.5 -i "testsrc2=size=320x180:rate=30" `
        -vf "select='eq(n,0)+eq(n,1)+eq(n,3)+eq(n,4)+eq(n,7)+eq(n,8)+eq(n,9)+eq(n,13)'" `
        -fps_mode vfr -c:v libx264 -pix_fmt yuv420p `
        $vfrFixture
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível gerar a fixture VFR."
    }

    $vfrFrames = & $ffprobe `
        -v error -select_streams v:0 -count_frames `
        -show_entries stream=nb_read_frames `
        -of default=nokey=1:noprint_wrappers=1 `
        $vfrFixture
    if ($LASTEXITCODE -ne 0 -or $vfrFrames -ne "8") {
        throw "A fixture VFR deveria conter 8 quadros; recebeu $vfrFrames."
    }
    Invoke-ZigDecoderTest -Fixture $vfrFixture -ExpectedFrames 8 -RequireVfr
} finally {
    $env:PATH = $originalPath

    Remove-Item -LiteralPath $cfrFixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vfrFixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDirectory -ErrorAction SilentlyContinue
}
