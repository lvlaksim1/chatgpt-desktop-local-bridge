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
$updateLog = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs\update-last.log'

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

Write-Result @{
    status = 'success'
    app_exists = (Test-Path -LiteralPath $appExe -PathType Leaf)
    release_tag = if ($null -ne $release) { [string]$release.tag } else { $null }
    release_commit = if ($null -ne $release) { [string]$release.commit } else { $null }
    app_version = if ($null -ne $release) { [string]$release.appVersion } else { $null }
    processes = $apps
    update_log_tail = $tail
}
