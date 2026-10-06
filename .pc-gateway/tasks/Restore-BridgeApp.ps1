[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ProcessName = 'ChatGptDesktopLocalBridge'
$taskName = 'ChatGptDesktopLocalBridge-Restore-' + [Guid]::NewGuid().ToString('N')
$scheduler = $null
$rootFolder = $null
$registered = $null

function Write-Result {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        throw "Installed application is missing at '$AppExe'."
    }

    $existing = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1)

    if ($existing.Count -gt 0) {
        Write-Result -Status 'success' -ExitCode 0 -Extra @{
            already_running = $true
            pid = [int]$existing[0].Id
            session_id = [int]$existing[0].SessionId
        }
    }

    # Task Scheduler is used deliberately here. Starting the long-lived GUI
    # directly from the gateway PowerShell leaves it in the process tree that
    # Repo-PowerShell.ps1 waits on. InteractiveToken makes Task Scheduler own
    # the child while still launching it in the signed-in user's desktop.
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $rootFolder = $scheduler.GetFolder('')
    $definition = $scheduler.NewTask(0)

    $definition.RegistrationInfo.Description =
        'One-shot restore of ChatGPT Desktop Local Bridge after PC Gateway diagnostics.'
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.ExecutionTimeLimit = 'PT5M'
    $definition.Principal.LogonType = 3  # TASK_LOGON_INTERACTIVE_TOKEN
    $definition.Principal.RunLevel = 0  # TASK_RUNLEVEL_LUA

    $trigger = $definition.Triggers.Create(1) # TASK_TRIGGER_TIME
    $trigger.StartBoundary = [DateTime]::Now.AddMinutes(2).ToString('s')
    $trigger.Enabled = $true

    $action = $definition.Actions.Create(0) # TASK_ACTION_EXEC
    $action.Path = $AppExe
    $action.WorkingDirectory = $InstallRoot

    $registered = $rootFolder.RegisterTaskDefinition(
        $taskName,
        $definition,
        6,       # TASK_CREATE_OR_UPDATE
        $null,
        $null,
        3,       # TASK_LOGON_INTERACTIVE_TOKEN
        $null)

    [void]$registered.Run($null)

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $app = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $items = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)
        if ($items.Count -gt 0) {
            $app = $items[0]
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $app) {
        throw 'Application did not expose a main window after Task Scheduler launch.'
    }

    try { $rootFolder.DeleteTask($taskName, 0) } catch {}

    Write-Result -Status 'success' -ExitCode 0 -Extra @{
        already_running = $false
        pid = [int]$app.Id
        session_id = [int]$app.SessionId
        runner_session_id = [int](Get-Process -Id $PID).SessionId
        same_session = ([int]$app.SessionId -eq [int](Get-Process -Id $PID).SessionId)
        launch_owner = 'TaskScheduler/InteractiveToken'
    }
}
catch {
    try {
        if ($null -ne $rootFolder) { $rootFolder.DeleteTask($taskName, 0) }
    }
    catch {}
    Write-Result -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}
finally {
    foreach ($com in @($registered, $rootFolder, $scheduler)) {
        if ($null -ne $com) {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } catch {}
        }
    }
}
