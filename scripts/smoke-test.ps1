param(
    [string]$Zig = "zig",
    [string]$Ffmpeg = "ffmpeg",
    [string]$Ffprobe = "ffprobe"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$smokeDir = Join-Path $repoRoot ".zig-cache\smoke"
New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null

$inputPath = Join-Path $smokeDir "synthetic-shaky.mp4"
$outputPath = Join-Path $smokeDir "synthetic-stabilized.mp4"

& $Zig build
if ($LASTEXITCODE -ne 0) {
    throw "zig build failed with exit code $LASTEXITCODE"
}

& $Ffmpeg -hide_banner -loglevel error -y `
    -f lavfi -i "testsrc2=size=672x392:rate=30:duration=3" `
    -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=3" `
    -vf "crop=640:360:x='16+10*sin(n*0.47)':y='16+8*cos(n*0.31)'" `
    -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p `
    -c:a aac -b:a 128k -shortest $inputPath
if ($LASTEXITCODE -ne 0) {
    throw "synthetic video generation failed with exit code $LASTEXITCODE"
}

& (Join-Path $repoRoot "zig-out\bin\axia-cli.exe") $inputPath $outputPath
if ($LASTEXITCODE -ne 0) {
    throw "axia-cli failed with exit code $LASTEXITCODE"
}

$probe = & $Ffprobe -v error `
    -show_entries "format=duration:stream=codec_type,codec_name,width,height" `
    -of "default=noprint_wrappers=1" $outputPath
if ($LASTEXITCODE -ne 0) {
    throw "output probe failed with exit code $LASTEXITCODE"
}

$probeText = $probe -join "`n"
if ($probeText -notmatch "codec_type=video" -or $probeText -notmatch "codec_type=audio") {
    throw "stabilized output does not contain both video and audio streams"
}

Write-Output $probeText
Write-Output "Smoke test passed: $outputPath"
