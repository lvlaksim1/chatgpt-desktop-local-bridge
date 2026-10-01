[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Result([hashtable]$payload, [int]$exitCode = 0) {
    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $exitCode
}

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$action = 'inspect'
if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['action']) {
    $action = [string]$request.args.action
}

$runnerSession = (Get-Process -Id $PID).SessionId
$apps = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)

if ($apps.Count -eq 0) {
    Write-Result @{
        status = 'app_not_running'
        runner_session = $runnerSession
        runner_user = [Environment]::UserName
        action = $action
    } 2
}

$appInfo = @()
foreach ($p in $apps) {
    $path = $null
    try { $path = $p.Path } catch {}
    $appInfo += @{
        pid = $p.Id
        session_id = $p.SessionId
        main_window_handle = [int64]$p.MainWindowHandle
        main_window_title = $p.MainWindowTitle
        path = $path
    }
}

$target = @($apps | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
if ($target.Count -eq 0) {
    Write-Result @{
        status = 'no_main_window'
        runner_session = $runnerSession
        runner_user = [Environment]::UserName
        action = $action
        processes = $appInfo
    } 3
}
$target = $target[0]

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$target.MainWindowHandle)
if ($null -eq $root) {
    Write-Result @{
        status = 'uia_root_unavailable'
        runner_session = $runnerSession
        app_session = $target.SessionId
        action = $action
        processes = $appInfo
    } 4
}

function Snapshot-Ui {
    param([System.Windows.Automation.AutomationElement]$Root)

    $buttons = New-Object System.Collections.ArrayList
    $texts = New-Object System.Collections.ArrayList
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)

    foreach ($el in $all) {
        try {
            $name = [string]$el.Current.Name
            $controlType = $el.Current.ControlType
            if ($controlType -eq [System.Windows.Automation.ControlType]::Button -and -not [string]::IsNullOrWhiteSpace($name)) {
                [void]$buttons.Add($name)
            }
            elseif ($controlType -eq [System.Windows.Automation.ControlType]::Text -and -not [string]::IsNullOrWhiteSpace($name)) {
                [void]$texts.Add($name)
            }
        }
        catch {}
    }

    return @{
        buttons = @($buttons | Select-Object -Unique | Select-Object -First 30)
        texts = @($texts | Select-Object -Unique | Select-Object -First 40)
    }
}

$before = Snapshot-Ui -Root $root
$invokeResult = $null

if ($action -eq 'initialize') {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        'Initialize Bridge')
    $button = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)

    if ($null -eq $button) {
        Write-Result @{
            status = 'initialize_button_not_found'
            runner_session = $runnerSession
            app_session = $target.SessionId
            action = $action
            before = $before
            processes = $appInfo
        } 5
    }

    $patternObj = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObj)) {
        Write-Result @{
            status = 'initialize_button_not_invokable'
            runner_session = $runnerSession
            app_session = $target.SessionId
            action = $action
            before = $before
            processes = $appInfo
        } 6
    }

    ([System.Windows.Automation.InvokePattern]$patternObj).Invoke()
    Start-Sleep -Seconds 8
    $invokeResult = 'invoked'
}

$after = Snapshot-Ui -Root $root

Write-Result @{
    status = 'success'
    runner_session = $runnerSession
    runner_user = [Environment]::UserName
    app_session = $target.SessionId
    same_session = ($runnerSession -eq $target.SessionId)
    action = $action
    initialize = $invokeResult
    before = $before
    after = $after
    processes = $appInfo
} 0
