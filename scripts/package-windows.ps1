param(
    [string]$Zig = "zig",
    [string]$FfmpegRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\ffmpeg-8.1-shared",
    [string]$OpenCvRoot = "$env:LOCALAPPDATA\Programs\AxiaDeps\opencv-4.13.0-zig"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifestPath = Join-Path $repoRoot "build.zig.zon"
$manifest = Get-Content -LiteralPath $manifestPath -Raw
$versionMatch = [regex]::Match($manifest, '\.version\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) {
    throw "Não foi possível ler a versão de build.zig.zon."
}
$version = $versionMatch.Groups[1].Value
$packageName = "axia-video-stabilize-$version-windows-x86_64"

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

$ffmpegExecutable = Join-Path $ffmpegBinary "ffmpeg.exe"
$ffprobeExecutable = Join-Path $ffmpegBinary "ffprobe.exe"
foreach ($requiredFile in @($ffmpegExecutable, $ffprobeExecutable)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Executável obrigatório não encontrado: $requiredFile"
    }
}

function Copy-NativeBinary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $destination = Join-Path $DestinationDirectory ([IO.Path]::GetFileName($Source))
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "Duas dependências diferentes possuem o mesmo nome: $destination"
        }
        return
    }
    Copy-Item -LiteralPath $Source -Destination $destination
}

function Copy-DependencyLicenses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $licenseFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File |
        Where-Object { $_.Name -match '^(?i:license|copying|notice)(\..*)?$' }
    foreach ($file in $licenseFiles) {
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart([char[]]"\/")
        $destination = Join-Path (Join-Path $DestinationDirectory $Label) $relative
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
}

function New-ReproducibleZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,
        [Parameter(Mandatory = $true)]
        [string]$RootName,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    $fileStream = [IO.File]::Open(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $fixedTimestamp = [DateTimeOffset]::new(
                1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero
            )
            $sourcePath = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\', '/')
            $files = Get-ChildItem -LiteralPath $sourcePath -Recurse -File |
                Sort-Object FullName
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($sourcePath.Length).TrimStart([char[]]"\/")
                $entryName = $RootName + "/" + $relative.Replace('\', '/')
                $entry = $archive.CreateEntry(
                    $entryName,
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = $fixedTimestamp
                $inputStream = [IO.File]::OpenRead($file.FullName)
                try {
                    $outputStream = $entry.Open()
                    try {
                        $inputStream.CopyTo($outputStream)
                    } finally {
                        $outputStream.Dispose()
                    }
                } finally {
                    $inputStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "axia-windows-package-" + [Guid]::NewGuid().ToString("N")
)
$buildPrefix = Join-Path $temporaryRoot "build"
$packageDirectory = Join-Path $temporaryRoot $packageName
$licensesDirectory = Join-Path $packageDirectory "licenses"
$distDirectory = Join-Path $repoRoot "dist"
$archivePath = Join-Path $distDirectory "$packageName.zip"
$checksumPath = "$archivePath.sha256"

New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $licensesDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

try {
    $buildArguments = @(
        "build",
        "--prefix", $buildPrefix,
        "-Doptimize=ReleaseFast",
        "-Dffmpeg-include=$ffmpegInclude",
        "-Dffmpeg-lib=$ffmpegLibrary",
        "-Dopencv-include=$opencvInclude",
        "-Dopencv-lib=$opencvLibrary"
    )
    & $Zig @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "A build de release falhou com o código $LASTEXITCODE."
    }

    Copy-Item -LiteralPath (Join-Path $buildPrefix "bin\axia-video-stabilize.exe") `
        -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $buildPrefix "bin\axia-cli.exe") `
        -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") `
        -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $repoRoot "src\assets\fonts\OFL.txt") `
        -Destination (Join-Path $licensesDirectory "Montserrat-OFL.txt")

    foreach ($binary in @($ffmpegExecutable, $ffprobeExecutable)) {
        Copy-NativeBinary -Source $binary -DestinationDirectory $packageDirectory
    }
    foreach ($directory in @($ffmpegBinary, $opencvBinary)) {
        Get-ChildItem -LiteralPath $directory -Filter "*.dll" -File |
            ForEach-Object {
                Copy-NativeBinary -Source $_.FullName -DestinationDirectory $packageDirectory
            }
    }

    if (-not (Get-ChildItem -LiteralPath $packageDirectory -Filter "avcodec-*.dll" -File)) {
        throw "O pacote não recebeu a DLL do avcodec."
    }
    if (-not (Get-ChildItem -LiteralPath $packageDirectory -Filter "opencv_core*.dll" -File)) {
        throw "O pacote não recebeu a DLL principal do OpenCV."
    }

    Copy-DependencyLicenses -Root $FfmpegRoot -Label "ffmpeg" `
        -DestinationDirectory $licensesDirectory
    Copy-DependencyLicenses -Root $OpenCvRoot -Label "opencv" `
        -DestinationDirectory $licensesDirectory

    $packageInfo = @(
        "Axia Video Stabilize $version",
        "Candidato de release para Windows 10/11 x86_64.",
        "Execute axia-video-stabilize.exe para abrir a interface.",
        "ffmpeg.exe e as bibliotecas nativas estão incluídos neste diretório."
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $packageDirectory "PACOTE.txt") `
        -Value $packageInfo -Encoding UTF8

    New-ReproducibleZip -SourceDirectory $packageDirectory `
        -RootName $packageName -Destination $archivePath

    $verifyRoot = Join-Path $temporaryRoot "verify"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $verifyRoot
    $verifiedPackage = Join-Path $verifyRoot $packageName
    $versionOutput = & (Join-Path $verifiedPackage "axia-cli.exe") --version
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join "`n") -notmatch [regex]::Escape($version)) {
        throw "A CLI extraída não iniciou ou informou uma versão incorreta."
    }
    & (Join-Path $verifiedPackage "ffmpeg.exe") -version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "O FFmpeg incluído no pacote não iniciou corretamente."
    }

    $smokeInput = Join-Path $temporaryRoot "package-smoke-input.mkv"
    $smokeOutput = Join-Path $temporaryRoot "package-smoke-output.mp4"
    & (Join-Path $verifiedPackage "ffmpeg.exe") `
        -hide_banner -loglevel error -y `
        -f lavfi -i "testsrc2=size=320x180:rate=15:duration=1" `
        -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=1" `
        -c:v mpeg4 -q:v 5 -c:a pcm_s16le -shortest $smokeInput
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível gerar a mídia de verificação do pacote."
    }

    $originalFfmpegOverride = $env:AXIA_FFMPEG
    try {
        $env:AXIA_FFMPEG = ""
        & (Join-Path $verifiedPackage "axia-cli.exe") $smokeInput $smokeOutput
        if ($LASTEXITCODE -ne 0) {
            throw "A estabilização de verificação do pacote falhou."
        }
    } finally {
        $env:AXIA_FFMPEG = $originalFfmpegOverride
    }

    $probeOutput = & (Join-Path $verifiedPackage "ffprobe.exe") `
        -v error -show_entries "stream=codec_type,codec_name" `
        -of "default=noprint_wrappers=1" $smokeOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível inspecionar a exportação de verificação."
    }
    $probeText = $probeOutput -join "`n"
    if (
        $probeText -notmatch "codec_type=video" -or
        $probeText -notmatch "codec_name=h264" -or
        $probeText -notmatch "codec_type=audio" -or
        $probeText -notmatch "codec_name=aac"
    ) {
        throw "A exportação de verificação não contém vídeo H.264 e áudio AAC."
    }

    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumLine = "$archiveHash  $([IO.Path]::GetFileName($archivePath))"
    Set-Content -LiteralPath $checksumPath -Value $checksumLine -Encoding ASCII

    Write-Output "versão: $version"
    Write-Output "pacote: $archivePath"
    Write-Output "checksum: $checksumPath"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
