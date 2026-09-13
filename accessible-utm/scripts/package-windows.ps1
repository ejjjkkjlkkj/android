param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [Parameter(Mandatory = $true)]
    [string]$QemuDirectory,

    [string]$OutputDirectory = 'accessible-utm/dist',

    [long]$SourceDateEpoch = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$qemuSource = (Resolve-Path -LiteralPath $QemuDirectory).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))

function Get-GitText {
    param([string[]]$Arguments)
    $text = (& git -C $repoRoot @Arguments 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $null }
    return $text
}

function Require-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label missing: $Path"
    }
}

if ($SourceDateEpoch -le 0) {
    if (-not [string]::IsNullOrWhiteSpace($env:SOURCE_DATE_EPOCH)) {
        $parsedEpoch = 0L
        if (-not [long]::TryParse($env:SOURCE_DATE_EPOCH, [ref]$parsedEpoch) -or $parsedEpoch -le 0) {
            throw "SOURCE_DATE_EPOCH must be a positive Unix timestamp, got '$env:SOURCE_DATE_EPOCH'."
        }
        $SourceDateEpoch = $parsedEpoch
    }
    else {
        $gitEpoch = Get-GitText -Arguments @('show', '-s', '--format=%ct', 'HEAD')
        $parsedEpoch = 0L
        if ([string]::IsNullOrWhiteSpace($gitEpoch) -or -not [long]::TryParse($gitEpoch, [ref]$parsedEpoch) -or $parsedEpoch -le 0) {
            throw 'A deterministic timestamp is required. Set SOURCE_DATE_EPOCH or run packaging from a Git checkout.'
        }
        $SourceDateEpoch = $parsedEpoch
    }
}

$packageTime = [DateTimeOffset]::FromUnixTimeSeconds($SourceDateEpoch)
if ($packageTime.Year -lt 1980 -or $packageTime.Year -gt 2107) {
    throw "SOURCE_DATE_EPOCH resolves to $packageTime, outside the ZIP timestamp range."
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
    Require-File -Path (Join-Path $qemuSource $name) -Label "Bundled QEMU component"
}

$qemuVersionText = (& (Join-Path $qemuSource 'qemu-system-x86_64.exe') --version | Select-Object -First 1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $qemuVersionText -notmatch 'QEMU emulator version\s+(?<version>[^\s]+)') {
    throw "Unable to determine bundled QEMU version from '$qemuVersionText'."
}
$qemuVersion = $Matches.version

$packageName = "AccessibleUTM-$version-windows-x64-portable"
$stage = Join-Path $output $packageName
$zip = Join-Path $output "$packageName.zip"

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item -LiteralPath $exePath -Destination (Join-Path $stage 'AccessibleUTM.exe')
Copy-Item -LiteralPath (Join-Path $repoRoot 'accessible-utm\README.md') -Destination (Join-Path $stage 'README.md')
Copy-Item -LiteralPath $qemuSource -Destination (Join-Path $stage 'qemu') -Recurse -Force

$launcher = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$exe = Join-Path $PSScriptRoot 'AccessibleUTM.exe'
$qemu = Join-Path $PSScriptRoot 'qemu\qemu-system-x86_64.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing $exe" }
if (-not (Test-Path -LiteralPath $qemu -PathType Leaf)) { throw "Bundled QEMU runtime is incomplete: $qemu" }
& $exe @args
exit $LASTEXITCODE
'@
Set-Content -LiteralPath (Join-Path $stage 'Start-AccessibleUTM.ps1') -Value $launcher -Encoding UTF8

$verifyRuntime = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$required = @(
  'AccessibleUTM.exe',
  'qemu\qemu-system-x86_64.exe',
  'qemu\qemu-system-aarch64.exe',
  'qemu\qemu-system-riscv64.exe',
  'qemu\qemu-img.exe'
)
foreach ($relative in $required) {
  $path = Join-Path $PSScriptRoot $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $relative" }
  Write-Host "PASS $relative"
}
& (Join-Path $PSScriptRoot 'AccessibleUTM.exe') --version
& (Join-Path $PSScriptRoot 'qemu\qemu-system-x86_64.exe') --version | Select-Object -First 1
& (Join-Path $PSScriptRoot 'qemu\qemu-system-aarch64.exe') --version | Select-Object -First 1
& (Join-Path $PSScriptRoot 'qemu\qemu-system-riscv64.exe') --version | Select-Object -First 1
Write-Host 'ACCESSIBLE_UTM_PORTABLE_RUNTIME = PASS'
'@
Set-Content -LiteralPath (Join-Path $stage 'Verify-Runtime.ps1') -Value $verifyRuntime -Encoding UTF8

$notices = @"
AccessibleUTM portable Windows package

Bundled virtualization runtime: QEMU $qemuVersion
QEMU project: https://www.qemu.org/
Windows binary distribution: https://qemu.weilnetz.de/w64/
Pinned installer used by CI: qemu-w64-setup-20260811.exe
QEMU is free/open-source software. The original QEMU license and notice files distributed with the runtime remain inside the qemu directory.

This package is designed to run without installing QEMU globally and without modifying PATH.
"@
Set-Content -LiteralPath (Join-Path $stage 'THIRD-PARTY-NOTICES.txt') -Value $notices -Encoding UTF8

$sourceCommit = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) { $env:GITHUB_SHA } else { Get-GitText -Arguments @('rev-parse', 'HEAD') }
$sourceBranch = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) { $env:GITHUB_REF_NAME } else { Get-GitText -Arguments @('branch', '--show-current') }
if ([string]::IsNullOrWhiteSpace($sourceBranch)) { $sourceBranch = 'detached' }

$manifest = [ordered]@{
    product = 'AccessibleUTM Windows Portable'
    version = $version
    architecture = 'x64'
    qemu_version = $qemuVersion
    qemu_runtime = 'bundled'
    qemu_installer = 'qemu-w64-setup-20260811.exe'
    qemu_installer_sha512 = '5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543'
    source_branch = $sourceBranch
    source_commit = $sourceCommit
    source_date_epoch = $SourceDateEpoch
    packaged_utc = $packageTime.UtcDateTime.ToString('o')
    zip_compression = 'store'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8

$fixedUtc = $packageTime.UtcDateTime
foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
    $file.LastWriteTimeUtc = $fixedUtc
}

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName) {
    if ($file.Name -eq 'SHA256SUMS.txt' -and $file.DirectoryName -eq $stage) { continue }
    $relative = [System.IO.Path]::GetRelativePath($stage, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
$hashLines | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ASCII
(Get-Item -LiteralPath (Join-Path $stage 'SHA256SUMS.txt')).LastWriteTimeUtc = $fixedUtc

& (Join-Path $stage 'Verify-Runtime.ps1')
if ($LASTEXITCODE -ne 0) { throw "Portable runtime verification failed: $LASTEXITCODE" }

Add-Type -AssemblyName System.IO.Compression
$zipStream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $archive = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false, [System.Text.Encoding]::UTF8)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName) {
            $relative = [System.IO.Path]::GetRelativePath($stage, $file.FullName).Replace('\', '/')
            $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = $packageTime
            $input = [System.IO.File]::OpenRead($file.FullName)
            try {
                $entryStream = $entry.Open()
                try { $input.CopyTo($entryStream) } finally { $entryStream.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
finally { $zipStream.Dispose() }

$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host 'ACCESSIBLE_UTM_PORTABLE_PACKAGE = PASS'
Write-Host 'ACCESSIBLE_UTM_BUNDLED_QEMU = PASS'
Write-Host 'ACCESSIBLE_UTM_PACKAGE_REPRODUCIBLE_INPUTS = PASS'
Write-Host "QEMU_VERSION = $qemuVersion"
Write-Host "PACKAGE_SOURCE_DATE_EPOCH = $SourceDateEpoch"
Write-Host "PACKAGE_ZIP = $zip"
Write-Host "PACKAGE_SHA256 = $zipHash"
