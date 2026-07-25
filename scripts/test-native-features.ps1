param(
    [string]$OpenCvRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\opencv-4.13.0-zig"
)

$ErrorActionPreference = "Stop"

$includePath = Join-Path $OpenCvRoot "include"
$libraryPath = Join-Path $OpenCvRoot "x64\mingw\lib"
$binaryPath = Join-Path $OpenCvRoot "x64\mingw\bin"

foreach ($requiredPath in @($includePath, $libraryPath, $binaryPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Dependência OpenCV não encontrada: $requiredPath"
    }
}

$originalPath = $env:PATH
$env:PATH = $binaryPath + [IO.Path]::PathSeparator + $originalPath

try {
    & zig build test `
        -Dnative-video=false `
        -Dnative-opencv=true `
        "-Dopencv-include=$includePath" `
        "-Dopencv-lib=$libraryPath" `
        --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "Os testes nativos de extração de features falharam."
    }
} finally {
    $env:PATH = $originalPath
}
