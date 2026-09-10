param(
    [string]$Iso = "",

    [string]$Disk = "$PSScriptRoot\..\.work\vm\accessible-android.qcow2",

    [string]$AccessibleUtmExe = "$PSScriptRoot\..\accessible-utm\target\release\accessible-utm.exe",

    [string]$QemuExe = "",

    [ValidateRange(1024, 65536)]
    [int]$MemoryMiB = 8192,

    [ValidateRange(1, 32)]
    [int]$Cpus = 6,

    [ValidateRange(8, 1024)]
    [int]$NewDiskGiB = 64,

    [switch]$NoAutostart,

    [switch]$RequireExistingDisk
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$AccessibleUtmExe = [System.IO.Path]::GetFullPath($AccessibleUtmExe)

if ($Iso) {
    $Iso = [System.IO.Path]::GetFullPath($Iso)
    if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
        throw "AccessibleAndroid ISO not found: $Iso"
    }
}

if ($Disk) {
    $Disk = [System.IO.Path]::GetFullPath($Disk)
}

if (-not $Iso -and -not $Disk) {
    throw 'Provide -Iso, -Disk, or both.'
}

if (-not (Test-Path -LiteralPath $AccessibleUtmExe -PathType Leaf)) {
    throw "AccessibleUTM executable not found: $AccessibleUtmExe. Build it with: cargo build --release --manifest-path accessible-utm/Cargo.toml"
}

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
$QemuExe = [System.IO.Path]::GetFullPath($QemuExe)

if ($Disk -and -not (Test-Path -LiteralPath $Disk -PathType Leaf)) {
    if ($RequireExistingDisk) {
        throw "Requested existing Android disk was not found: $Disk"
    }
    if (-not $Iso) {
        throw "Android disk not found and no ISO was supplied to install from: $Disk"
    }

    $diskDirectory = Split-Path -Parent $Disk
    New-Item -ItemType Directory -Force -Path $diskDirectory | Out-Null

    $qemuImg = Join-Path (Split-Path -Parent $QemuExe) 'qemu-img.exe'
    if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) {
        $qemuImgCommand = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
        if ($qemuImgCommand) {
            $qemuImg = $qemuImgCommand.Source
        }
    }
    if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) {
        throw 'qemu-img.exe was not found, so a new Android QCOW2 disk cannot be created.'
    }

    Write-Host "Creating Android installation disk: $Disk ($NewDiskGiB GiB)"
    & $qemuImg create -f qcow2 $Disk "${NewDiskGiB}G"
    if ($LASTEXITCODE -ne 0) {
        throw "qemu-img failed with exit code $LASTEXITCODE"
    }
}

$argsList = @(
    '--profile', 'accessible-android',
    '--arch', 'x86_64',
    '--name', 'AccessibleAndroid',
    '--qemu', $QemuExe,
    '--memory', $MemoryMiB,
    '--cpus', $Cpus
)

if ($Iso) {
    $argsList += @('--iso', $Iso)
}
if ($Disk) {
    $argsList += @('--disk', $Disk)
}
if (-not $NoAutostart) {
    $argsList += '--autostart'
}

Write-Host 'Starting AccessibleAndroid through AccessibleUTM Windows'
Write-Host "REPO=$repoRoot"
Write-Host "ACCESSIBLE_UTM=$AccessibleUtmExe"
Write-Host "ISO=$Iso"
Write-Host "DISK=$Disk"
Write-Host "QEMU=$QemuExe"
Write-Host "MEMORY_MIB=$MemoryMiB"
Write-Host "CPUS=$Cpus"
Write-Host 'ANDROID_OS_DISK_PCI=0000:00:06.0'

Start-Process -FilePath $AccessibleUtmExe -ArgumentList $argsList
