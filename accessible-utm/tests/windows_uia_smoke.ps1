param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exePath = (Resolve-Path -LiteralPath $Executable).Path
$configPath = Join-Path $env:RUNNER_TEMP 'accessible-utm-uia-smoke.json'
Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AccessibleUtmFocus {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@

function Get-UiAutomationSnapshot {
    param([System.Windows.Automation.AutomationElement]$Root)

    $items = [System.Collections.Generic.List[object]]::new()
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    for ($index = 0; $index -lt $all.Count; $index++) {
        $element = $all.Item($index)
        try {
            $items.Add([pscustomobject]@{
                Name = [string]$element.Current.Name
                ControlType = [string]$element.Current.ControlType.ProgrammaticName
                IsEnabled = [bool]$element.Current.IsEnabled
                AutomationId = [string]$element.Current.AutomationId
            })
        }
        catch {
            # Elements can disappear between the tree query and property reads.
        }
    }
    return $items
}

function Wait-ForNamedElement {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name,
        [int]$TimeoutMilliseconds = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $snapshot = @(Get-UiAutomationSnapshot -Root $Root)
        $match = $snapshot | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    $names = ($snapshot | Where-Object Name | Select-Object -ExpandProperty Name -Unique) -join "`n  - "
    throw "UIA element '$Name' was not exposed. Seen names:`n  - $names"
}

$process = Start-Process -FilePath $exePath -ArgumentList @('--config', $configPath) -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($process.HasExited) {
            throw "AccessibleUTM exited before exposing a window. Exit code: $($process.ExitCode)"
        }
        $process.Refresh()
        if ($process.MainWindowHandle -ne 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($process.MainWindowHandle -eq 0) {
        throw 'AccessibleUTM did not expose a top-level Windows window within the timeout.'
    }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    if ($null -eq $root) {
        throw 'UI Automation could not attach to the AccessibleUTM top-level window.'
    }

    $required = @(
        'AccessibleUTM Windows',
        'VM name',
        'QEMU executable',
        'Boot ISO path',
        'Virtual disk path',
        'Start virtual machine (F5)',
        'Pause virtual machine (F6)',
        'Resume virtual machine (F7)',
        'Request graceful shutdown (F8)',
        'Print QEMU command (F9)',
        'Save configuration (Ctrl+S)',
        'Load configuration (Ctrl+O)'
    )

    foreach ($name in $required) {
        [void](Wait-ForNamedElement -Root $root -Name $name)
    }

    $before = @(Get-UiAutomationSnapshot -Root $root)
    if ($before.Name -contains 'QEMU command printed to stdout.') {
        throw 'Unexpected precondition: F9 status was already present before keyboard injection.'
    }

    [void][AccessibleUtmFocus]::SetForegroundWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('{F9}')

    [void](Wait-ForNamedElement -Root $root -Name 'QEMU command printed to stdout.' -TimeoutMilliseconds 5000)

    $snapshot = @(Get-UiAutomationSnapshot -Root $root)
    $snapshot |
        Sort-Object ControlType, Name -Unique |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'accessible-utm-uia-tree.json') -Encoding UTF8

    Write-Host 'ACCESSIBLE_UTM_UIA_TREE = PASS'
    Write-Host 'ACCESSIBLE_UTM_KEYBOARD_F9 = PASS'
    Write-Host "ACCESSIBLE_UTM_UIA_ELEMENT_COUNT = $($snapshot.Count)"
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}
