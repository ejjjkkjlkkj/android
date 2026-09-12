param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [string]$OutputDirectory = 'accessible-utm/dist',

    [long]$SourceDateEpoch = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))

function Get-GitText {
    param([string[]]$Arguments)

    $text = (& git -C $repoRoot @Arguments 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return $text
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
$packageName = "AccessibleUTM-$version-windows-x64"
$stage = Join-Path $output $packageName
$zip = Join-Path $output "$packageName.zip"

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item -LiteralPath $exePath -Destination (Join-Path $stage 'AccessibleUTM.exe')
Copy-Item -LiteralPath (Join-Path $repoRoot 'accessible-utm\README.md') -Destination (Join-Path $stage 'README.md')

$launcher = @'
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'AccessibleUTM.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Missing $exe" }
& $exe @args
exit $LASTEXITCODE
'@
Set-Content -LiteralPath (Join-Path $stage 'Start-AccessibleUTM.ps1') -Value $launcher -Encoding UTF8

$installQemu = @'
$ErrorActionPreference = 'Stop'
if (Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue) {
    Write-Host 'QEMU is already available on PATH.'
    exit 0
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget.exe is not available. Install QEMU manually from the official QEMU distribution.'
}
winget install --id SoftwareFreedomConservancy.QEMU --exact --accept-package-agreements --accept-source-agreements
if ($LASTEXITCODE -ne 0) { throw "winget QEMU installation failed with exit code $LASTEXITCODE" }
Write-Host 'QEMU installation completed. Reopen the terminal before launching AccessibleUTM.'
'@
Set-Content -LiteralPath (Join-Path $stage 'Install-QEMU.ps1') -Value $installQemu -Encoding UTF8

$sourceCommit = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
    $env:GITHUB_SHA
}
else {
    Get-GitText -Arguments @('rev-parse', 'HEAD')
}
$sourceBranch = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
    $env:GITHUB_REF_NAME
}
else {
    Get-GitText -Arguments @('branch', '--show-current')
}
if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
    $sourceBranch = 'detached'
}

$manifest = [ordered]@{
    product = 'AccessibleUTM Windows'
    version = $version
    architecture = 'x64'
    source_branch = $sourceBranch
    source_commit = $sourceCommit
    source_date_epoch = $SourceDateEpoch
    packaged_utc = $packageTime.UtcDateTime.ToString('o')
    zip_compression = 'store'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $stage -File | Sort-Object Name) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($file.Name)"
}
$hashLines | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ASCII

$fixedUtc = $packageTime.UtcDateTime
foreach ($file in Get-ChildItem -LiteralPath $stage -File) {
    $file.LastWriteTimeUtc = $fixedUtc
}

Add-Type -AssemblyName System.IO.Compression
$zipStream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $zipStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false,
        [System.Text.Encoding]::UTF8
    )
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -File | Sort-Object Name) {
            $entry = $archive.CreateEntry($file.Name, [System.IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = $packageTime
            $input = [System.IO.File]::OpenRead($file.FullName)
            try {
                $entryStream = $entry.Open()
                try {
                    $input.CopyTo($entryStream)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
            finally {
                $input.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $zipStream.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host 'ACCESSIBLE_UTM_PACKAGE = PASS'
Write-Host 'ACCESSIBLE_UTM_PACKAGE_REPRODUCIBLE_INPUTS = PASS'
Write-Host "PACKAGE_SOURCE_DATE_EPOCH = $SourceDateEpoch"
Write-Host "PACKAGE_ZIP = $zip"
Write-Host "PACKAGE_SHA256 = $zipHash"
