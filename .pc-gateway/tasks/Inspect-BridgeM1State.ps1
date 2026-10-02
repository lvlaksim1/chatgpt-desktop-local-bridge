[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Result {
    param([hashtable]$Payload, [int]$ExitCode = 0)
    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($Payload | ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$releaseInfoPath = Join-Path $installRoot 'release-info.json'
$appExe = Join-Path $installRoot 'ChatGptDesktopLocalBridge.exe'
$logRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$updateLog = Join-Path $logRoot 'update-last.log'

$release = $null
if (Test-Path -LiteralPath $releaseInfoPath -PathType Leaf) {
    try { $release = Get-Content -LiteralPath $releaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

$apps = @()
foreach ($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $p.Path } catch {}
    $apps += @{
        pid = $p.Id
        session_id = $p.SessionId
        main_window_handle = [int64]$p.MainWindowHandle
        title = $p.MainWindowTitle
        path = $path
    }
}

$tail = ''
if (Test-Path -LiteralPath $updateLog -PathType Leaf) {
    $tail = (@(Get-Content -LiteralPath $updateLog -Tail 30 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
}

$bridgeLog = $null
$bridgeLogTail = @()
if (Test-Path -LiteralPath $logRoot -PathType Container) {
    $candidate = @(Get-ChildItem -LiteralPath $logRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1)
    if ($candidate.Count -gt 0) {
        $bridgeLog = $candidate[0].FullName
        $bridgeLogTail = @(Get-Content -LiteralPath $bridgeLog -Tail 80 -ErrorAction SilentlyContinue)
    }
}

$details = @{
    app_exists = (Test-Path -LiteralPath $appExe -PathType Leaf)
    release_tag = if ($null -ne $release) { [string]$release.tag } else { $null }
    release_commit = if ($null -ne $release) { [string]$release.commit } else { $null }
    app_version = if ($null -ne $release) { [string]$release.appVersion } else { $null }
    processes = $apps
    update_log_tail = $tail
    bridge_log = $bridgeLog
    bridge_log_tail = $bridgeLogTail
}

Write-Result @{
    status = 'diagnostic'
    error = ($details | ConvertTo-Json -Depth 12 -Compress)
    app_exists = $details.app_exists
    release_tag = $details.release_tag
    release_commit = $details.release_commit
    app_version = $details.app_version
    processes = $details.processes
    update_log_tail = $details.update_log_tail
    bridge_log = $details.bridge_log
    bridge_log_tail = $details.bridge_log_tail
} 31
