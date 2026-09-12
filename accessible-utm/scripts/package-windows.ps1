param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [string]$OutputDirectory = 'accessible-utm/dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))

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

$manifest = [ordered]@{
    product = 'AccessibleUTM Windows'
    version = $version
    architecture = 'x64'
    source_branch = $env:GITHUB_REF_NAME
    source_commit = $env:GITHUB_SHA
    packaged_utc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $stage -File | Sort-Object Name) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($file.Name)"
}
$hashLines | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ASCII

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "ACCESSIBLE_UTM_PACKAGE = PASS"
Write-Host "PACKAGE_ZIP = $zip"
Write-Host "PACKAGE_SHA256 = $zipHash"
