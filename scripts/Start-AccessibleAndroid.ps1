param(
    [Parameter(Mandatory = $true)]
    [string]$Iso,

    [string]$Disk = "$PSScriptRoot\..\.work\vm\accessible-android.qcow2",

    [string]$AccessibleQemuExe = "$PSScriptRoot\..\accessible-qemu\target\release\accessible-qemu.exe",

    [string]$QemuExe = "",

    [ValidateRange(1024, 32768)]
    [int]$MemoryMiB = 4096,

    [ValidateRange(1, 16)]
    [int]$Cpus = 4,

    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'

$Iso = [System.IO.Path]::GetFullPath($Iso)
$Disk = [System.IO.Path]::GetFullPath($Disk)
$AccessibleQemuExe = [System.IO.Path]::GetFullPath($AccessibleQemuExe)

if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
    throw "Accessible Android ISO not found: $Iso"
}

if (-not (Test-Path -LiteralPath $AccessibleQemuExe -PathType Leaf)) {
    throw "AccessibleQEMU executable not found: $AccessibleQemuExe. Build it with: cargo build --release --manifest-path accessible-qemu/Cargo.toml"
}

$diskDirectory = Split-Path -Parent $Disk
New-Item -ItemType Directory -Force -Path $diskDirectory | Out-Null

if (-not $QemuExe) {
    $qemuCommand = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
    if ($qemuCommand) {
        $QemuExe = $qemuCommand.Source
    } elseif (Test-Path 'C:\Program Files\qemu\qemu-system-x86_64.exe') {
        $QemuExe = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
    } elseif (Test-Path 'C:\Program Files (x86)\qemu\qemu-system-x86_64.exe') {
        $QemuExe = 'C:\Program Files (x86)\qemu\qemu-system-x86_64.exe'
    }
}

if (-not $QemuExe -or -not (Test-Path -LiteralPath $QemuExe -PathType Leaf)) {
    throw 'QEMU x86_64 was not found. Install QEMU or pass -QemuExe explicitly.'
}

if (-not (Test-Path -LiteralPath $Disk -PathType Leaf)) {
    $qemuImg = Join-Path (Split-Path -Parent $QemuExe) 'qemu-img.exe'
    if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) {
        $qemuImgCommand = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
        if ($qemuImgCommand) {
            $qemuImg = $qemuImgCommand.Source
        }
    }

    if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) {
        throw 'qemu-img.exe was not found, so the default QCOW2 disk cannot be created.'
    }

    Write-Host "Creating virtual disk: $Disk"
    & $qemuImg create -f qcow2 $Disk 64G
    if ($LASTEXITCODE -ne 0) {
        throw "qemu-img failed with exit code $LASTEXITCODE"
    }
}

$argsList = @(
    '--iso', $Iso,
    '--disk', $Disk,
    '--qemu', $QemuExe,
    '--memory', $MemoryMiB,
    '--cpus', $Cpus
)

if (-not $NoAutostart) {
    $argsList += '--autostart'
}

Write-Host 'Starting AccessibleQEMU'
Write-Host "ISO=$Iso"
Write-Host "DISK=$Disk"
Write-Host "QEMU=$QemuExe"
Write-Host "MEMORY_MIB=$MemoryMiB"
Write-Host "CPUS=$Cpus"

Start-Process -FilePath $AccessibleQemuExe -ArgumentList $argsList
