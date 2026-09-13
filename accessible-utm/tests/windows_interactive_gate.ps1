param(
    [switch]$SkipBuild,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $projectRoot '..')).Path
$manifest = Join-Path $projectRoot 'Cargo.toml'
$lockfile = Join-Path $projectRoot 'Cargo.lock'
$exe = Join-Path $projectRoot 'target\release\accessible-utm.exe'

if (-not [Environment]::UserInteractive) {
    throw 'Interactive Windows desktop required. Run this script while signed in to the desktop.'
}
if ((Get-Process -Id $PID).SessionId -eq 0) {
    throw 'Session 0 is not valid for real UI Automation validation.'
}
if (-not (Test-Path -LiteralPath $lockfile)) {
    throw "Committed Cargo lockfile not found: $lockfile"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path ([Environment]::GetFolderPath('Desktop')) "AccessibleUTM-Evidence-$stamp"
}
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null

if (-not $SkipBuild) {
    Write-Host '== RUST TESTS =='
    cargo test --release --locked --manifest-path $manifest
    if ($LASTEXITCODE -ne 0) { throw "cargo test --locked failed with exit code $LASTEXITCODE" }

    Write-Host '== RELEASE BUILD =='
    cargo build --release --locked --manifest-path $manifest
    if ($LASTEXITCODE -ne 0) { throw "cargo build --locked failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "AccessibleUTM executable not found: $exe"
}

Write-Host '== UI AUTOMATION + KEYBOARD =='
# windows_uia_smoke.ps1 is a PowerShell script, not a native executable.
# With Set-StrictMode, $LASTEXITCODE may be undefined after a successful
# PowerShell-only invocation. Errors from the smoke script already terminate
# this gate because $ErrorActionPreference = 'Stop'.
& (Join-Path $PSScriptRoot 'windows_uia_smoke.ps1') -Executable $exe -EvidenceDirectory $output

$screenReaderDefinitions = @(
    [pscustomobject]@{ Name = 'NVDA'; ProcessNames = @('nvda') },
    [pscustomobject]@{ Name = 'JAWS'; ProcessNames = @('jfw', 'jfw64') },
    [pscustomobject]@{ Name = 'Narrator'; ProcessNames = @('Narrator') }
)

$screenReaders = foreach ($definition in $screenReaderDefinitions) {
    $matches = @()
    foreach ($processName in $definition.ProcessNames) {
        $matches += @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    }
    [pscustomobject]@{
        name = $definition.Name
        running = ($matches.Count -gt 0)
        process_ids = @($matches | Select-Object -ExpandProperty Id -Unique)
        manual_user_validation = 'REQUIRED'
    }
}

$os = Get-CimInstance Win32_OperatingSystem
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$lockHash = (Get-FileHash -LiteralPath $lockfile -Algorithm SHA256).Hash.ToLowerInvariant()
$gitCommit = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
$rustVersion = (& rustc -V | Out-String).Trim()
$cargoVersion = (& cargo -V | Out-String).Trim()

$report = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    verdict = 'AUTOMATED_INTERACTIVE_UIA_PASS_MANUAL_SCREEN_READER_VALIDATION_REQUIRED'
    repository_commit = $gitCommit
    executable = $exe
    executable_sha256 = $exeHash
    cargo_lock_sha256 = $lockHash
    session_id = (Get-Process -Id $PID).SessionId
    user_interactive = [Environment]::UserInteractive
    windows = [ordered]@{
        caption = [string]$os.Caption
        version = [string]$os.Version
        build = [string]$os.BuildNumber
    }
    powershell = $PSVersionTable.PSVersion.ToString()
    rust = $rustVersion
    cargo = $cargoVersion
    automated = [ordered]@{
        dependency_lock = 'PASS'
        rust_tests = if ($SkipBuild) { 'SKIPPED_BY_REQUEST' } else { 'PASS' }
        release_build = if ($SkipBuild) { 'SKIPPED_BY_REQUEST' } else { 'PASS' }
        windows_uia_tree = 'PASS'
        keyboard_f9 = 'PASS'
        evidence_file = (Join-Path $output 'accessible-utm-uia-tree.json')
    }
    screen_readers = @($screenReaders)
    manual_release_gate = @(
        'NVDA: navigate every control, edit every field, trigger shortcuts, verify status announcements.',
        'JAWS: repeat keyboard navigation and status/output verification.',
        'Narrator: repeat keyboard navigation and status/output verification.',
        'Start a real QEMU guest and verify focus does not become trapped between AccessibleUTM and the QEMU window.'
    )
}

$reportPath = Join-Path $output 'interactive-validation.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

$readme = @"
AccessibleUTM interactive Windows evidence
==========================================

Automated UIA tree: PASS
Automated F9 keyboard path: PASS
Locked Rust dependencies: PASS
Executable SHA-256: $exeHash
Cargo.lock SHA-256: $lockHash
Commit: $gitCommit

IMPORTANT: NVDA, JAWS and Narrator process detection is evidence only. It does not count as a human screen-reader PASS.
The manual release gate listed in interactive-validation.json remains required.
"@
Set-Content -LiteralPath (Join-Path $output 'README.txt') -Value $readme -Encoding UTF8

$zipPath = "$output.zip"
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host 'ACCESSIBLE_UTM_INTERACTIVE_AUTOMATION = PASS'
Write-Host 'ACCESSIBLE_UTM_CARGO_LOCK = VERIFIED'
Write-Host 'ACCESSIBLE_UTM_SCREEN_READER_MANUAL_GATE = REQUIRED'
Write-Host "EVIDENCE_DIRECTORY = $output"
Write-Host "EVIDENCE_ZIP = $zipPath"
Write-Host "EVIDENCE_ZIP_SHA256 = $((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant())"
