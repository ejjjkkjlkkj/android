param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [Parameter(Mandatory = $true)]
    [string]$QemuDirectory,

    [string]$AndroidImage = '',

    [string]$OutputDirectory = 'accessible-utm/dist-single'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$qemuSource = (Resolve-Path -LiteralPath $QemuDirectory).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))

function Require-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label missing: $Path"
    }
}

$versionText = (& $exePath --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^AccessibleUTM\s+(?<version>[^\s]+)$') {
    throw "Unable to determine AccessibleUTM version from '$versionText'."
}
$version = $Matches.version

$qemuRequired = @(
    'qemu-system-x86_64.exe',
    'qemu-system-aarch64.exe',
    'qemu-system-riscv64.exe',
    'qemu-img.exe'
)
foreach ($name in $qemuRequired) {
    Require-File -Path (Join-Path $qemuSource $name) -Label 'QEMU runtime component'
}

$qemuVersionText = (& (Join-Path $qemuSource 'qemu-system-x86_64.exe') --version | Select-Object -First 1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $qemuVersionText -notmatch 'QEMU emulator version\s+(?<version>[^\s]+)') {
    throw "Unable to determine QEMU version from '$qemuVersionText'."
}
$qemuVersion = $Matches.version

New-Item -ItemType Directory -Path $output -Force | Out-Null
$outExe = Join-Path $output 'AccessibleUTM.exe'
Remove-Item -LiteralPath $outExe -Force -ErrorAction SilentlyContinue

$payloadRoot = Join-Path $env:RUNNER_TEMP "accessible-utm-single-payload-$PID"
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $payloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) "accessible-utm-single-payload-$PID"
}
Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null

$qemuDestination = Join-Path $payloadRoot 'qemu'
Copy-Item -LiteralPath $qemuSource -Destination $qemuDestination -Recurse -Force
Get-ChildItem -LiteralPath $qemuDestination -File -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $qemuDestination -File -Filter 'unins*.dat' -ErrorAction SilentlyContinue | Remove-Item -Force

$androidIncluded = $false
$androidSha256 = $null
$androidSize = $null
if (-not [string]::IsNullOrWhiteSpace($AndroidImage)) {
    $androidSource = (Resolve-Path -LiteralPath $AndroidImage).Path
    Require-File -Path $androidSource -Label 'AccessibleAndroid image'
    $imagesDir = Join-Path $payloadRoot 'images'
    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    $androidDestination = Join-Path $imagesDir 'AccessibleAndroid.qcow2'
    Copy-Item -LiteralPath $androidSource -Destination $androidDestination -Force
    $androidIncluded = $true
    $androidSha256 = (Get-FileHash -LiteralPath $androidDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $androidSize = (Get-Item -LiteralPath $androidDestination).Length
}

$manifest = [ordered]@{
    format = 'AUTM_PAYLOAD_V1'
    product = 'AccessibleUTM Windows single executable'
    version = $version
    qemu_version = $qemuVersion
    qemu_runtime = 'embedded'
    android_image_included = $androidIncluded
    android_image_sha256 = $androidSha256
    android_image_size = $androidSize
    extraction_root = '%LOCALAPPDATA%/AccessibleUTM/runtime'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $payloadRoot 'package-manifest.json') -Encoding UTF8

$notices = @"
AccessibleUTM single-file Windows package

The user-facing deliverable is one file: AccessibleUTM.exe.
The executable contains its complete QEMU runtime and QEMU firmware/data files.
On first launch the embedded payload is extracted automatically to the current user's LocalAppData cache.
No global QEMU installation, PATH modification, winget operation, Visual C++ redistributable installation, or administrator installation step is required by AccessibleUTM itself.

Bundled virtualization runtime: QEMU $qemuVersion
QEMU project: https://www.qemu.org/
Pinned Windows distribution source: https://qemu.weilnetz.de/w64/
Pinned installer used while constructing the payload: qemu-w64-setup-20260811.exe
Pinned installer SHA-512: 5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543

QEMU and included third-party components remain subject to their respective licenses. Their files and license materials are preserved inside the embedded runtime payload.
"@
Set-Content -LiteralPath (Join-Path $payloadRoot 'THIRD-PARTY-NOTICES.txt') -Value $notices -Encoding UTF8

$files = @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse | Sort-Object {
    [System.IO.Path]::GetRelativePath($payloadRoot, $_.FullName).Replace('\', '/')
})
if ($files.Count -eq 0) { throw 'Embedded payload contains no files.' }

Copy-Item -LiteralPath $exePath -Destination $outExe -Force

$stream = [System.IO.File]::Open($outExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
    $payloadStart = [UInt64]$stream.Position
    $writer = [System.IO.BinaryWriter]::new($stream, [System.Text.Encoding]::UTF8, $true)
    try {
        foreach ($file in $files) {
            $relative = [System.IO.Path]::GetRelativePath($payloadRoot, $file.FullName).Replace('\', '/')
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($relative)
            if ($pathBytes.Length -eq 0 -or $pathBytes.Length -gt 32768) {
                throw "Payload path length is invalid: $relative"
            }

            $writer.Write([UInt32]$pathBytes.Length)
            $writer.Write([UInt64]$file.Length)
            $writer.Write($pathBytes)
            $writer.Flush()

            $input = [System.IO.File]::OpenRead($file.FullName)
            try {
                $input.CopyTo($stream)
            }
            finally {
                $input.Dispose()
            }
        }

        $payloadLength = [UInt64]($stream.Position - [Int64]$payloadStart)
        $magic = [System.Text.Encoding]::ASCII.GetBytes('AUTM_PAYLOAD_V1!')
        if ($magic.Length -ne 16) { throw "Invalid payload magic length: $($magic.Length)" }
        $writer.Write($magic)
        $writer.Write([UInt64]$payloadStart)
        $writer.Write([UInt32]$files.Count)
        $writer.Write([UInt64]$payloadLength)
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$finalSize = (Get-Item -LiteralPath $outExe).Length
$finalHash = (Get-FileHash -LiteralPath $outExe -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host 'ACCESSIBLE_UTM_SINGLE_EXE = PASS'
Write-Host 'ACCESSIBLE_UTM_EMBEDDED_QEMU = PASS'
Write-Host "ACCESSIBLE_UTM_VERSION = $version"
Write-Host "QEMU_VERSION = $qemuVersion"
Write-Host "ANDROID_IMAGE_INCLUDED = $androidIncluded"
if ($androidIncluded) {
    Write-Host "ANDROID_IMAGE_SHA256 = $androidSha256"
    Write-Host "ANDROID_IMAGE_SIZE = $androidSize"
}
Write-Host "PAYLOAD_FILE_COUNT = $($files.Count)"
Write-Host "OUTPUT_EXE = $outExe"
Write-Host "OUTPUT_SIZE = $finalSize"
Write-Host "OUTPUT_SHA256 = $finalHash"

Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
