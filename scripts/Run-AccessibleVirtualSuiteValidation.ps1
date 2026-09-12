param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AccessibleUTM', 'AccessibleAndroid')]
    [string]$Target,

    [string]$Repository = 'ejjjkkjlkkj/android',
    [string]$Branch = 'accessible-virtual-suite',

    [switch]$Watch,

    [switch]$BootstrapAndroidHost,
    [switch]$ForceKernelRebuild,
    [switch]$ForceAccessibilityRebuild,
    [switch]$ExportAllAndroidDiskFormats,
    [switch]$UploadAndroidDiskArtifact,
    [switch]$AllowBelowRecommendedAndroidResources,

    [ValidateRange(1, 256)]
    [int]$AndroidBuildJobs = 16,

    [ValidateRange(1, 64)]
    [int]$KernelSyncJobs = 8
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh failed with exit code $LASTEXITCODE: gh $($Arguments -join ' ')"
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required and was not found on PATH.'
}

Write-Host '== GITHUB AUTH =='
Invoke-Gh auth status

$workflow = switch ($Target) {
    'AccessibleUTM' { 'accessible-utm-uia-self-hosted.yml' }
    'AccessibleAndroid' { 'preinstalled-android-self-hosted.yml' }
}

Write-Host "TARGET = $Target"
Write-Host "REPOSITORY = $Repository"
Write-Host "BRANCH = $Branch"
Write-Host "WORKFLOW = $workflow"

$arguments = @(
    'workflow', 'run', $workflow,
    '--repo', $Repository,
    '--ref', $Branch
)

if ($Target -eq 'AccessibleAndroid') {
    $arguments += @(
        '-f', "bootstrap_host=$($BootstrapAndroidHost.IsPresent.ToString().ToLowerInvariant())",
        '-f', "android_build_jobs=$AndroidBuildJobs",
        '-f', "kernel_sync_jobs=$KernelSyncJobs",
        '-f', "force_kernel_rebuild=$($ForceKernelRebuild.IsPresent.ToString().ToLowerInvariant())",
        '-f', "force_accessibility_rebuild=$($ForceAccessibilityRebuild.IsPresent.ToString().ToLowerInvariant())",
        '-f', "export_all_formats=$($ExportAllAndroidDiskFormats.IsPresent.ToString().ToLowerInvariant())",
        '-f', "upload_disk_artifact=$($UploadAndroidDiskArtifact.IsPresent.ToString().ToLowerInvariant())",
        '-f', "allow_below_recommended_resources=$($AllowBelowRecommendedAndroidResources.IsPresent.ToString().ToLowerInvariant())"
    )
}

Write-Host '== DISPATCH =='
Invoke-Gh @arguments
Write-Host 'WORKFLOW_DISPATCH = PASS'

Start-Sleep -Seconds 2

$runJson = & gh run list --repo $Repository --workflow $workflow --branch $Branch --limit 1 --json databaseId,status,conclusion,headSha,url,displayTitle,createdAt
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve the dispatched workflow run. gh exit code: $LASTEXITCODE"
}

$runs = @($runJson | ConvertFrom-Json)
if ($runs.Count -eq 0) {
    throw 'Workflow dispatch succeeded but no matching run could be resolved.'
}

$run = $runs[0]
Write-Host "RUN_ID = $($run.databaseId)"
Write-Host "RUN_STATUS = $($run.status)"
Write-Host "RUN_SHA = $($run.headSha)"
Write-Host "RUN_URL = $($run.url)"

if ($Watch) {
    Write-Host '== WATCH =='
    Invoke-Gh run watch ([string]$run.databaseId) --repo $Repository --exit-status
    Write-Host 'WORKFLOW_RESULT = PASS'
}
else {
    Write-Host 'WORKFLOW_RESULT = DISPATCHED'
    Write-Host "To follow it: gh run watch $($run.databaseId) --repo $Repository --exit-status"
}
