[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$ExpectedTag = 'dev-f4a3433'
$ProcessName = 'ChatGptDesktopLocalBridge'

function Finish {
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
        expected_tag = $ExpectedTag
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($payload | ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

function Stop-Bridge {
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try {
            if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
        } catch {}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $needle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $needle + '*') })) {
        try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop } catch {}
    }
}

function Wait-App {
    param([int]$TimeoutSeconds = 40)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)
        if ($p.Count -gt 0) { return $p[0] }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Get-UiState {
    param([System.Windows.Automation.AutomationElement]$Root)

    $texts = New-Object System.Collections.Generic.List[string]
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)

    foreach ($el in $all) {
        try {
            if ($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) {
                $name = [string]$el.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) { $texts.Add($name) }
            }
        } catch {}
    }

    return @($texts | Select-Object -Unique)
}

function Invoke-Button {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    $button = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($null -eq $button) { throw "Button '$Name' was not found." }

    $pattern = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) {
        throw "Button '$Name' is not invokable."
    }
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        throw "Application executable is missing: $AppExe"
    }

    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) {
        throw 'release-info.json is missing.'
    }

    $release = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$release.tag -ne $ExpectedTag) {
        throw "Unexpected installed release '$($release.tag)'; expected '$ExpectedTag'."
    }

    Write-Host ('BRIDGE_INIT_STAGE=release-ok:' + [string]$release.tag)

    Stop-Bridge
    Start-Process -FilePath $AppExe | Out-Null

    $proc = Wait-App
    if ($null -eq $proc) { throw 'Application main window did not appear.' }
    Write-Host 'BRIDGE_INIT_STAGE=window-ready'

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$proc.MainWindowHandle)
    if ($null -eq $root) { throw 'UI Automation root is unavailable.' }

    $transitions = New-Object System.Collections.Generic.List[object]

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $pageReady = $false
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        $texts = @(Get-UiState -Root $root)
        $status = @($texts | Where-Object {
            $_ -like 'ChatGPT ready.*' -or
            $_ -like 'Navigation failed:*'
        } | Select-Object -First 1)

        if ($status.Count -gt 0) {
            $transitions.Add([ordered]@{ at=[DateTimeOffset]::UtcNow.ToString('o'); text=[string]$status[0] })
            if ([string]$status[0] -like 'Navigation failed:*') {
                Finish -Status 'fail' -ExitCode 31 -ErrorText ([string]$status[0]) -Extra @{
                    release_tag = [string]$release.tag
                    transitions = $transitions
                }
            }
            $pageReady = $true
            break
        }

        Start-Sleep -Milliseconds 250
    }

    if (-not $pageReady) {
        $texts = @(Get-UiState -Root $root)
        Finish -Status 'fail' -ExitCode 31 -ErrorText 'ChatGPT page did not reach ready state within 30 seconds.' -Extra @{
            release_tag = [string]$release.tag
            ui_texts = $texts
            transitions = $transitions
        }
    }

    Invoke-Button -Root $root -Name 'Initialize Bridge'
    $transitions.Add([ordered]@{ at=[DateTimeOffset]::UtcNow.ToString('o'); text='Initialize Bridge invoked' })
    Write-Host 'BRIDGE_INIT_STAGE=initialize-clicked'

    $deadline = [DateTime]::UtcNow.AddSeconds(75)
    $lastStatus = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $texts = @(Get-UiState -Root $root)
        $status = @($texts | Where-Object {
            $_ -like 'Bridge ready. Session*' -or
            $_ -like 'Bootstrap sent. Waiting for bridge handshake*' -or
            $_ -like 'Chat send failed:*' -or
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*' -or
            $_ -like 'Bridge error:*'
        } | Select-Object -First 1)

        if ($status.Count -gt 0) {
            $current = [string]$status[0]
            if ($current -ne $lastStatus) {
                $lastStatus = $current
                $transitions.Add([ordered]@{ at=[DateTimeOffset]::UtcNow.ToString('o'); text=$current })
                Write-Host ('BRIDGE_INIT_STAGE=status:' + $current)
            }

            if ($current -like 'Bridge ready. Session*') {
                Finish -Status 'pass' -ExitCode 0 -Extra @{
                    release_tag = [string]$release.tag
                    release_commit = [string]$release.commit
                    final_status = $current
                    transitions = $transitions
                }
            }

            if ($current -like 'Chat send failed:*' -or
                $current -like 'Could not send bridge bootstrap*' -or
                $current -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
                $current -like 'Bridge initialization failed:*' -or
                $current -like 'Bridge error:*') {
                Finish -Status 'fail' -ExitCode 31 -ErrorText $current -Extra @{
                    release_tag = [string]$release.tag
                    release_commit = [string]$release.commit
                    final_status = $current
                    transitions = $transitions
                }
            }
        }

        Start-Sleep -Milliseconds 250
    }

    $texts = @(Get-UiState -Root $root)
    Finish -Status 'fail' -ExitCode 31 -ErrorText 'Initialize Bridge did not reach PASS/FAIL state within 75 seconds.' -Extra @{
        release_tag = [string]$release.tag
        release_commit = [string]$release.commit
        final_status = $lastStatus
        ui_texts = $texts
        transitions = $transitions
    }
}
catch {
    Finish -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}