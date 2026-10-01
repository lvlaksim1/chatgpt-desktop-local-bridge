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
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $json = $payload | ConvertTo-Json -Depth 12
    $json | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    $compact = $payload | ConvertTo-Json -Depth 12 -Compress
    Write-Host ("PC_GATEWAY_PROJECT_RESULT_JSON=" + $compact)
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
    param([int]$TimeoutSeconds = 45)

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
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$values.Add($name)
                }
            }
        } catch {}
    }

    return @($values | Select-Object -Unique)
}

function Invoke-Button {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    $button = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)

    if ($null -eq $button) { throw "$Name button not found." }

    $pattern = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        throw "$Name button is not invokable."
    }

    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$project = Join-Path $repoRoot 'src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj'
$publishDir = Join-Path $env:TEMP ("chatgpt-bridge-native-input-" + [Guid]::NewGuid().ToString('N'))
$installedExe = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$wasRunning = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue).Count -gt 0

$terminal = 'not_started'
$finalStatus = ''
$buildTail = ''
$exitCode = 50

try {
    New-Item -ItemType Directory -Force -Path $publishDir | Out-Null

    $buildOutput = & dotnet publish $project --configuration Release --runtime win-x64 --self-contained true --output $publishDir 2>&1
    $buildExit = $LASTEXITCODE
    $buildTail = (@($buildOutput | Select-Object -Last 20) -join " | ")
    if ($buildExit -ne 0) {
        throw ("dotnet publish failed: " + $buildTail)
    }

    $candidateExe = Join-Path $publishDir 'ChatGptDesktopLocalBridge.exe'
    if (-not (Test-Path -LiteralPath $candidateExe -PathType Leaf)) {
        throw 'Candidate executable missing after publish.'
    }

    Stop-BridgeApp

    Start-Process -FilePath $candidateExe | Out-Null
    $process = Wait-BridgeProcess -TimeoutSeconds 45
    if ($null -eq $process) {
        throw 'Candidate app window did not appear.'
    }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    if ($null -eq $root) {
        throw 'UI Automation root is unavailable.'
    }

    $readyForInit = $false
    $preflightDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $preflightDeadline) {
        Start-Sleep -Seconds 1
        $texts = Get-UiTexts -Root $root
        $status = @($texts | Where-Object {
            $_ -like 'ChatGPT ready*' -or
            $_ -like 'Adapter v3:*'
        } | Select-Object -First 1)

        if ($status.Count -gt 0) {
            $readyForInit = $true
            break
        }
    }

    if (-not $readyForInit) {
        throw 'Candidate ChatGPT surface did not become ready.'
    }

    Invoke-Button -Root $root -Name 'Initialize Bridge'
    $terminal = 'waiting'

    $deadline = [DateTime]::UtcNow.AddSeconds(90)
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

        $failure = @($texts | Where-Object {
            $_ -like 'Chat send failed:*' -or
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*'
        } | Select-Object -First 1)

        if ($failure.Count -gt 0) {
            $finalStatus = [string]$failure[0]
            $terminal = 'failed'
            $exitCode = 21
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalStatus)) {
        $texts = Get-UiTexts -Root $root
        $finalStatus = (@($texts | Select-Object -Last 12) -join ' | ')
        if ($terminal -eq 'waiting') {
            $terminal = 'timeout'
            $exitCode = 22
        }
    }
}
catch {
    $terminal = 'exception'
    $finalStatus = $_.Exception.Message
    $exitCode = 31
}
finally {
    try { Stop-BridgeApp } catch {}

    if ($wasRunning -and (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        try { Start-Process -FilePath $installedExe | Out-Null } catch {}
    }

    try {
        Remove-Item -LiteralPath $publishDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}

if ($exitCode -eq 0) {
    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        terminal = $terminal
        final_status = $finalStatus
        build_tail = $buildTail
    }
}

Write-ProjectResult -Status 'fail' -ExitCode $exitCode -ErrorText $finalStatus -Extra @{
    terminal = $terminal
    final_status = $finalStatus
    build_tail = $buildTail
}
