param(
    [Parameter(Mandatory = $true)]
    [string]$Vmdk,
    [int]$TimeoutSeconds = 420,
    [string]$EvidenceDir = ".work\logs\vmware"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-Vmrun {
    $cmd = Get-Command vmrun.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe",
        "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "VMware vmrun.exe not found. VMware Workstation Pro is required on the Windows runner."
}

function To-VmxPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

$Vmdk = (Resolve-Path -LiteralPath $Vmdk).Path
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
$vmrun = Resolve-Vmrun

$work = Join-Path $env:RUNNER_TEMP ("AccessibleAndroid-VMware-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$vmx = Join-Path $work "AccessibleAndroid17.vmx"
$serialLog = Join-Path $work "serial.log"
$vmwareLog = Join-Path $work "vmware.log"

$vmdkVmx = To-VmxPath $Vmdk
$serialVmx = To-VmxPath $serialLog

@"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "AccessibleAndroid17-CI"
guestOS = "other6xlinux-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
numvcpus = "4"
memsize = "4096"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "$vmdkVmx"
sata0:0.deviceType = "disk"
serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "$serialVmx"
serial0.startConnected = "TRUE"
serial0.tryNoRxLoss = "FALSE"
serial0.yieldOnMsrRead = "TRUE"
sound.present = "TRUE"
sound.virtualDev = "hdaudio"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
usb.present = "TRUE"
usb_xhci.present = "TRUE"
msg.autoAnswer = "TRUE"
uuid.action = "create"
"@ | Set-Content -LiteralPath $vmx -Encoding UTF8

Write-Host "VMRUN=$vmrun"
Write-Host "VMDK=$Vmdk"
Write-Host "VMX=$vmx"

$started = $false
try {
    & $vmrun start $vmx nogui
    if ($LASTEXITCODE -ne 0) {
        throw "vmrun start failed with exit code $LASTEXITCODE"
    }
    $started = $true

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $postFs = $false
    $framework = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $serialLog) {
            $text = Get-Content -LiteralPath $serialLog -Raw -ErrorAction SilentlyContinue
            if ($text) {
                $postFs = $text.Contains("ACCESSIBLE_ANDROID_POST_FS_DATA=PASS")
                $framework = $text.Contains("ACCESSIBLE_ANDROID_FRAMEWORK_BOOT=PASS")
                if ($postFs -and $framework) { break }
            }
        }

        $running = & $vmrun list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "vmrun list failed while waiting for boot."
        } elseif (-not (($running | Out-String).Contains($vmx))) {
            throw "VMware VM stopped before Android framework boot completed."
        }

        Start-Sleep -Seconds 2
    }

    if (-not $postFs) {
        throw "VMware boot did not reach Android post-fs-data within $TimeoutSeconds seconds."
    }
    if (-not $framework) {
        throw "VMware boot did not reach sys.boot_completed=1 within $TimeoutSeconds seconds."
    }

    Write-Host "VMWARE_ANDROID_PARTITIONS = PASS"
    Write-Host "VMWARE_ANDROID_POST_FS_DATA = PASS"
    Write-Host "VMWARE_ANDROID_FRAMEWORK_BOOT = PASS"
}
finally {
    if ($started) {
        & $vmrun stop $vmx hard 2>&1 | Out-Host
    }

    if (Test-Path -LiteralPath $serialLog) {
        Copy-Item -LiteralPath $serialLog -Destination (Join-Path $EvidenceDir "serial.log") -Force
    }
    if (Test-Path -LiteralPath $vmwareLog) {
        Copy-Item -LiteralPath $vmwareLog -Destination (Join-Path $EvidenceDir "vmware.log") -Force
    }
    Copy-Item -LiteralPath $vmx -Destination (Join-Path $EvidenceDir "AccessibleAndroid17.vmx") -Force
}
