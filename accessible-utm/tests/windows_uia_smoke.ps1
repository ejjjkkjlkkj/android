param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exePath = (Resolve-Path -LiteralPath $Executable).Path

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $env:RUNNER_TEMP
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP
    }
    else {
        [System.IO.Path]::GetTempPath()
    }
}
else {
    $tempRoot = [System.IO.Path]::GetFullPath($EvidenceDirectory)
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$configPath = Join-Path $tempRoot 'accessible-utm-uia-smoke.json'
$treePath = Join-Path $tempRoot 'accessible-utm-uia-tree.json'
$failureTreePath = Join-Path $tempRoot 'accessible-utm-uia-tree-failure.json'

Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $treePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $failureTreePath -Force -ErrorAction SilentlyContinue

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

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@

function Add-UiAutomationElement {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [System.Windows.Automation.AutomationElement]$Element
    )

    try {
        $Items.Add([pscustomobject]@{
            Name = [string]$Element.Current.Name
            ControlType = [string]$Element.Current.ControlType.ProgrammaticName
            IsEnabled = [bool]$Element.Current.IsEnabled
            IsOffscreen = [bool]$Element.Current.IsOffscreen
            AutomationId = [string]$Element.Current.AutomationId
            ProcessId = [int]$Element.Current.ProcessId
            NativeWindowHandle = [int]$Element.Current.NativeWindowHandle
        })
    }
    catch {
        # UIA elements may disappear while the immediate-mode UI redraws.
    }
}

function Get-UiAutomationSnapshot {
    param([System.Windows.Automation.AutomationElement]$WindowElement)

    $items = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $WindowElement) {
        return @()
    }

    Add-UiAutomationElement -Items $items -Element $WindowElement

    try {
        $all = $WindowElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )

        for ($index = 0; $index -lt $all.Count; $index++) {
            Add-UiAutomationElement -Items $items -Element $all.Item($index)
        }
    }
    catch {
        # Keep the root information for diagnostics and retry.
    }

    return @($items)
}

function Get-AccessibleUtmWindow {
    param(
        [int]$ProcessId,
        [string]$ExpectedTitle = 'AccessibleUTM Windows',
        [int]$TimeoutMilliseconds = 20000
    )

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $pidCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId
    )
    $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window
    )
    $condition = New-Object System.Windows.Automation.AndCondition(
        $pidCondition,
        $windowCondition
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lastSeen = @()

    do {
        $candidates = $desktop.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            $condition
        )

        $lastSeen = @()
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            $candidate = $candidates.Item($index)
            try {
                $name = [string]$candidate.Current.Name
                $handle = [int]$candidate.Current.NativeWindowHandle
                $lastSeen += "$name [HWND=$handle]"

                if ($name -eq $ExpectedTitle) {
                    return $candidate
                }
            }
            catch {
            }
        }

        # Fallback: MainWindowHandle can become valid slightly before UIA's
        # desktop tree is updated. FromHandle also forces WM_GETOBJECT.
        try {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            $process.Refresh()
            if ($process.MainWindowHandle -ne 0) {
                $fromHandle = [System.Windows.Automation.AutomationElement]::FromHandle(
                    [IntPtr]$process.MainWindowHandle
                )
                if ($null -ne $fromHandle -and [string]$fromHandle.Current.Name -eq $ExpectedTitle) {
                    return $fromHandle
                }
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "AccessibleUTM top-level UIA window '$ExpectedTitle' was not found for PID $ProcessId. Seen: $($lastSeen -join '; ')"
}

function Wait-ForNamedElement {
    param(
        [System.Windows.Automation.AutomationElement]$WindowElement,
        [string]$Name,
        [int]$TimeoutMilliseconds = 12000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $snapshot = @()

    do {
        $snapshot = @(Get-UiAutomationSnapshot -WindowElement $WindowElement)
        $match = $snapshot |
            Where-Object { $_.Name -eq $Name } |
            Select-Object -First 1

        if ($null -ne $match) {
            return $match
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    $snapshot |
        Sort-Object ControlType, Name -Unique |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $failureTreePath -Encoding UTF8

    $names = ($snapshot |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
        Select-Object -ExpandProperty Name -Unique) -join "`n  - "

    throw "UIA element '$Name' was not exposed. Element count=$($snapshot.Count). Failure tree: $failureTreePath. Seen names:`n  - $names"
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

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    $window = Get-AccessibleUtmWindow -ProcessId $process.Id

    $nativeHandle = [IntPtr]$window.Current.NativeWindowHandle
    if ($nativeHandle -eq [IntPtr]::Zero) {
        throw 'AccessibleUTM UIA window has no native HWND.'
    }

    # Restore/show, foreground, then create real keyboard traffic. Querying the
    # AutomationElement above triggers WM_GETOBJECT and activates AccessKit's
    # Windows adapter; Tab requests another egui frame afterwards.
    [void][AccessibleUtmFocus]::ShowWindowAsync($nativeHandle, 9)
    [void][AccessibleUtmFocus]::SetForegroundWindow($nativeHandle)
    Start-Sleep -Milliseconds 350
    [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
    Start-Sleep -Milliseconds 700

    $initial = @(Get-UiAutomationSnapshot -WindowElement $window)
    if ($initial.Count -le 1) {
        # One extra activation cycle for systems where UIA/AccessKit starts
        # after the first provider request.
        [void]$window.GetCurrentPropertyValue(
            [System.Windows.Automation.AutomationElement]::NameProperty
        )
        [void][AccessibleUtmFocus]::SetForegroundWindow($nativeHandle)
        [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
        Start-Sleep -Milliseconds 1000
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
        [void](Wait-ForNamedElement -WindowElement $window -Name $name)
    }

    $before = @(Get-UiAutomationSnapshot -WindowElement $window)
    if ($before.Name -contains 'QEMU command printed to stdout.') {
        throw 'Unexpected precondition: F9 status was already present before keyboard injection.'
    }

    [void][AccessibleUtmFocus]::SetForegroundWindow($nativeHandle)
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('{F9}')

    [void](Wait-ForNamedElement `
        -WindowElement $window `
        -Name 'QEMU command printed to stdout.' `
        -TimeoutMilliseconds 5000)

    $snapshot = @(Get-UiAutomationSnapshot -WindowElement $window)

    $snapshot |
        Sort-Object ControlType, Name -Unique |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $treePath -Encoding UTF8

    Write-Host 'ACCESSIBLE_UTM_UIA_TREE = PASS'
    Write-Host 'ACCESSIBLE_UTM_KEYBOARD_F9 = PASS'
    Write-Host "ACCESSIBLE_UTM_UIA_ELEMENT_COUNT = $($snapshot.Count)"
    Write-Host "ACCESSIBLE_UTM_UIA_EVIDENCE = $treePath"
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}
