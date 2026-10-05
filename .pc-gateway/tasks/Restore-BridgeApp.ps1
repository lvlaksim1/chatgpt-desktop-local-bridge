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

    $shell = New-Object -ComObject Shell.Application
    try {
        $shell.ShellExecute($AppExe, '', $InstallRoot, 'open', 1)
    }
    finally {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {}
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
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
        throw 'Application did not expose a main window after ShellExecute.'
    }

    Write-Result -Status 'success' -ExitCode 0 -Extra @{
        already_running = $false
        pid = [int]$app.Id
        session_id = [int]$app.SessionId
        runner_session_id = [int](Get-Process -Id $PID).SessionId
        same_session = ([int]$app.SessionId -eq [int](Get-Process -Id $PID).SessionId)
    }
}
catch {
    Write-Result -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}
