param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [Parameter(Mandatory = $true)]
    [string]$QemuDirectory,

    [string]$AndroidImage = '',

    [string]$OutputDirectory = 'accessible-utm/dist',

    [long]$SourceDateEpoch = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$qemuSource = (Resolve-Path -LiteralPath $QemuDirectory).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
$androidImageSource = $null
if (-not [string]::IsNullOrWhiteSpace($AndroidImage)) {
    $androidImageSource = (Resolve-Path -LiteralPath $AndroidImage).Path
}

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
    Require-File -Path (Join-Path $qemuSource $name) -Label 'Bundled QEMU component'
}

$firmwareCandidates = @(
    (Join-Path $qemuSource 'share\edk2-x86_64-code.fd'),
    (Join-Path $qemuSource 'share\qemu\edk2-x86_64-code.fd'),
    (Join-Path $qemuSource 'edk2-x86_64-code.fd')
)
$qemuFirmware = $firmwareCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($qemuFirmware)) {
    throw "Bundled QEMU x86_64 UEFI firmware is missing. Checked: $($firmwareCandidates -join ', ')"
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

$androidImageIncluded = $false
$androidImageSha256 = $null
if ($null -ne $androidImageSource) {
    Require-File -Path $androidImageSource -Label 'AccessibleAndroid image'
    $imagesDir = Join-Path $stage 'images'
    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    $imageDestination = Join-Path $imagesDir 'AccessibleAndroid.qcow2'
    Copy-Item -LiteralPath $androidImageSource -Destination $imageDestination
    $androidImageIncluded = $true
    $androidImageSha256 = (Get-FileHash -LiteralPath $imageDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "ACCESSIBLE_ANDROID_IMAGE_SHA256 = $androidImageSha256"
}

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
$firmware = @(
  'qemu\share\edk2-x86_64-code.fd',
  'qemu\share\qemu\edk2-x86_64-code.fd',
  'qemu\edk2-x86_64-code.fd'
) | ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($firmware)) { throw 'Bundled x86_64 UEFI firmware is missing.' }
Write-Host "PASS UEFI firmware: $firmware"
& (Join-Path $PSScriptRoot 'AccessibleUTM.exe') --version
& (Join-Path $PSScriptRoot 'qemu\qemu-system-x86_64.exe') --version | Select-Object -First 1
& (Join-Path $PSScriptRoot 'qemu\qemu-system-aarch64.exe') --version | Select-Object -First 1
& (Join-Path $PSScriptRoot 'qemu\qemu-system-riscv64.exe') --version | Select-Object -First 1
$image = Join-Path $PSScriptRoot 'images\AccessibleAndroid.qcow2'
if (Test-Path -LiteralPath $image -PathType Leaf) { Write-Host 'PASS images\AccessibleAndroid.qcow2' }
Write-Host 'ACCESSIBLE_UTM_PORTABLE_RUNTIME = PASS'
'@
Set-Content -LiteralPath (Join-Path $stage 'Verify-Runtime.ps1') -Value $verifyRuntime -Encoding UTF8

$installTemplate = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = $PSScriptRoot
$verify = Join-Path $source 'Verify-Runtime.ps1'
if (-not (Test-Path -LiteralPath $verify -PathType Leaf)) { throw "Missing $verify" }
& $verify
if ($LASTEXITCODE -ne 0) { throw "Source runtime verification failed: $LASTEXITCODE" }
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\AccessibleUTM'
if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force
}
& (Join-Path $installRoot 'Verify-Runtime.ps1')
if ($LASTEXITCODE -ne 0) { throw "Installed runtime verification failed: $LASTEXITCODE" }
$target = Join-Path $installRoot 'AccessibleUTM.exe'
$shell = New-Object -ComObject WScript.Shell
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AccessibleUTM'
New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null
foreach ($shortcutPath in @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AccessibleUTM.lnk'),
    (Join-Path $startMenuDir 'AccessibleUTM.lnk')
)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'AccessibleUTM accessible virtual machine manager'
    $shortcut.Save()
}
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AccessibleUTM'
New-Item -Path $uninstallKey -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'AccessibleUTM' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '__VERSION__' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'AccessibleUTM' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
$uninstallScript = Join-Path $installRoot 'Uninstall-AccessibleUTM.ps1'
$uninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""
New-ItemProperty -Path $uninstallKey -Name UninstallString -Value $uninstallString -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "ACCESSIBLE_UTM_INSTALL = PASS"
Write-Host "INSTALL_ROOT = $installRoot"
'@
$installScript = $installTemplate.Replace('__VERSION__', $version)
Set-Content -LiteralPath (Join-Path $stage 'Install-AccessibleUTM.ps1') -Value $installScript -Encoding UTF8
Set-Content -LiteralPath (Join-Path $stage 'Install-AccessibleUTM.cmd') -Value '@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AccessibleUTM.ps1"
if errorlevel 1 pause
' -Encoding ASCII

$uninstallScript = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installRoot = $PSScriptRoot
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AccessibleUTM'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AccessibleUTM.lnk'
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AccessibleUTM' -Recurse -Force -ErrorAction SilentlyContinue
$cleanup = Join-Path $env:TEMP ("AccessibleUTM-uninstall-" + [guid]::NewGuid().ToString('N') + '.ps1')
$escaped = $installRoot.Replace("'", "''")
Set-Content -LiteralPath $cleanup -Encoding UTF8 -Value ("Start-Sleep -Milliseconds 800`r`nRemove-Item -LiteralPath '" + $escaped + "' -Recurse -Force -ErrorAction SilentlyContinue`r`nRemove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue")
Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$cleanup) -WindowStyle Hidden
Write-Host 'ACCESSIBLE_UTM_UNINSTALL = SCHEDULED'
'@
Set-Content -LiteralPath (Join-Path $stage 'Uninstall-AccessibleUTM.ps1') -Value $uninstallScript -Encoding UTF8

$notices = @"
AccessibleUTM portable Windows package

Bundled virtualization runtime: QEMU $qemuVersion
QEMU project: https://www.qemu.org/
Windows binary distribution: https://qemu.weilnetz.de/w64/
Pinned installer used by CI: qemu-w64-setup-20260811.exe
QEMU is free/open-source software. The original QEMU license and notice files distributed with the runtime remain inside the qemu directory.

This package runs without installing QEMU globally and without modifying PATH.
Install-AccessibleUTM.cmd installs per-user under LocalAppData and needs no administrator rights.
When images\AccessibleAndroid.qcow2 is included, AccessibleUTM discovers it automatically at startup.
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
    qemu_firmware = [System.IO.Path]::GetRelativePath($qemuSource, $qemuFirmware).Replace('\', '/')
    qemu_installer = 'qemu-w64-setup-20260811.exe'
    qemu_installer_sha512 = '5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543'
    install_mode = 'portable-or-per-user'
    admin_required = $false
    android_image_included = $androidImageIncluded
    android_image_sha256 = $androidImageSha256
    android_image_path = if ($androidImageIncluded) { 'images/AccessibleAndroid.qcow2' } else { $null }
    source_branch = $sourceBranch
    source_commit = $sourceCommit
    source_date_epoch = $SourceDateEpoch
    packaged_utc = $packageTime.UtcDateTime.ToString('o')
    zip_compression = 'store'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8

$fixedUtc = $packageTime.UtcDateTime
foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) { $file.LastWriteTimeUtc = $fixedUtc }

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
Write-Host 'ACCESSIBLE_UTM_BUNDLED_UEFI = PASS'
Write-Host 'ACCESSIBLE_UTM_PER_USER_INSTALLER = PASS'
Write-Host 'ACCESSIBLE_UTM_PACKAGE_REPRODUCIBLE_INPUTS = PASS'
Write-Host "QEMU_VERSION = $qemuVersion"
Write-Host "ANDROID_IMAGE_INCLUDED = $androidImageIncluded"
Write-Host "PACKAGE_SOURCE_DATE_EPOCH = $SourceDateEpoch"
Write-Host "PACKAGE_ZIP = $zip"
Write-Host "PACKAGE_SHA256 = $zipHash"
