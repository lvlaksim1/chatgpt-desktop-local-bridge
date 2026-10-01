[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-ProjectResult {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorText = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        status = $Status
        error = $ErrorText
        exit_code = $ExitCode
        restored_original_adapter = $script:restored
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-BridgeApp {
    $items = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)
    foreach ($p in $items) {
        try { [void]$p.CloseMainWindow() } catch {}
    }
    Start-Sleep -Seconds 2
    $items = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)
    foreach ($p in $items) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Seconds 1
}

function Wait-BridgeProcess {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)
        if ($p.Count -gt 0) { return $p[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Get-UiTexts {
    param([System.Windows.Automation.AutomationElement]$Root)
    $values = New-Object System.Collections.ArrayList
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        try {
            if ($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) {
                $name = [string]$el.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$values.Add($name) }
            }
        } catch {}
    }
    return @($values | Select-Object -Unique)
}

function Get-DiagnosticsDetails {
    param([System.Windows.Automation.AutomationElement]$Root)

    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            'Diagnostics')
        $button = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -eq $button) { return 'diagnostics-button-not-found' }

        $pattern = $null
        if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            return 'diagnostics-button-not-invokable'
        }

        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        Start-Sleep -Milliseconds 800

        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            'Local Bridge diagnostics')
        $dialog = $desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
        if ($null -eq $dialog) { return 'diagnostics-dialog-not-found' }

        $parts = New-Object System.Collections.ArrayList
        $all = $dialog.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)

        foreach ($el in $all) {
            try {
                $name = [string]$el.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$parts.Add($name)
                }
            } catch {}
        }

        $details = (@($parts | Select-Object -Unique) -join ' || ')

        try {
            $okCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'OK')
            $ok = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCondition)
            if ($null -ne $ok) {
                $okPattern = $null
                if ($ok.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$okPattern)) {
                    ([System.Windows.Automation.InvokePattern]$okPattern).Invoke()
                }
            }
        } catch {}

        return $details
    }
    catch {
        return ('diagnostics-exception:' + $_.Exception.Message)
    }
}

$script:restored = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$candidateAdapter = Join-Path $repoRoot 'src\ChatGptDesktopLocalBridge\Web\bridge-adapter.js'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$appExe = Join-Path $installRoot 'ChatGptDesktopLocalBridge.exe'
$installedAdapter = Join-Path $installRoot 'Web\bridge-adapter.js'

if (-not (Test-Path -LiteralPath $candidateAdapter -PathType Leaf)) {
    Write-ProjectResult -Status 'candidate_missing' -ExitCode 10 -ErrorText $candidateAdapter
}
if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
    Write-ProjectResult -Status 'installed_app_missing' -ExitCode 11 -ErrorText $appExe
}
if (-not (Test-Path -LiteralPath $installedAdapter -PathType Leaf)) {
    Write-ProjectResult -Status 'installed_adapter_missing' -ExitCode 12 -ErrorText $installedAdapter
}

$backup = Join-Path $env:TEMP ("bridge-adapter-backup-" + [Guid]::NewGuid().ToString('N') + ".js")
$wasRunning = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue).Count -gt 0
$finalStatus = ''
$terminal = 'timeout'
$exitCode = 30

try {
    Copy-Item -LiteralPath $installedAdapter -Destination $backup -Force
    Stop-BridgeApp
    Copy-Item -LiteralPath $candidateAdapter -Destination $installedAdapter -Force

    Start-Process -FilePath $appExe | Out-Null
    $process = Wait-BridgeProcess -TimeoutSeconds 30
    if ($null -eq $process) {
        throw 'Candidate app window did not appear.'
    }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    if ($null -eq $root) { throw 'UI Automation root is unavailable.' }

    $chatReady = $false
    $lastPreflight = ''
    $preflightDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $preflightDeadline) {
        Start-Sleep -Seconds 2
        $lastPreflight = Get-DiagnosticsDetails -Root $root
        if ($lastPreflight -match '"composerFound"\s*:\s*true' -and
            $lastPreflight -match '"readyState"\s*:\s*"complete"') {
            $chatReady = $true
            break
        }
    }
    if (-not $chatReady) {
        throw ('ChatGPT did not reach composer-ready state. Last diagnostics: ' + $lastPreflight)
    }

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        'Initialize Bridge')
    $button = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -eq $button) { throw 'Initialize Bridge button not found.' }

    $pattern = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        throw 'Initialize Bridge button is not invokable.'
    }

    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()

    $deadline = [DateTime]::UtcNow.AddSeconds(75)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $texts = Get-UiTexts -Root $root

        $ready = @($texts | Where-Object { $_ -like 'Bridge ready. Session*' } | Select-Object -First 1)
        if ($ready.Count -gt 0) {
            $finalStatus = [string]$ready[0]
            $terminal = 'ready'
            $exitCode = 0
            break
        }

        $sendFail = @($texts | Where-Object { $_ -like 'Chat send failed:*' } | Select-Object -First 1)
        if ($sendFail.Count -gt 0) {
            $finalStatus = [string]$sendFail[0]
            $terminal = 'send_failed'
            $exitCode = 21
            break
        }

        $bootstrapFail = @($texts | Where-Object {
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*'
        } | Select-Object -First 1)
        if ($bootstrapFail.Count -gt 0) {
            $finalStatus = [string]$bootstrapFail[0]
            $terminal = 'bootstrap_failed'
            $exitCode = 22
            break
        }
    }

    if ($exitCode -ne 0) {
        $diagnostics = Get-DiagnosticsDetails -Root $root
        if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
            $finalStatus = $finalStatus + ' || DIAGNOSTICS: ' + $diagnostics
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalStatus)) {
        $texts = Get-UiTexts -Root $root
        $finalStatus = (@($texts | Select-Object -Last 8) -join ' | ')
    }
}
catch {
    $terminal = 'exception'
    $finalStatus = $_.Exception.Message
    $exitCode = 31
}
finally {
    try {
        Stop-BridgeApp
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Copy-Item -LiteralPath $backup -Destination $installedAdapter -Force
            $script:restored = $true
        }
    } catch {}

    try {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    } catch {}

    if ($wasRunning -and (Test-Path -LiteralPath $appExe -PathType Leaf)) {
        try { Start-Process -FilePath $appExe | Out-Null } catch {}
    }
}

if ($exitCode -eq 0) {
    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        terminal = $terminal
        final_status = $finalStatus
    }
}

Write-ProjectResult -Status 'fail' -ExitCode $exitCode -ErrorText $finalStatus -Extra @{
    terminal = $terminal
    final_status = $finalStatus
}
