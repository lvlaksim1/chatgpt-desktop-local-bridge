[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$probeId = [string]$request.args.probe_id
if ([string]::IsNullOrWhiteSpace($probeId) -or $probeId -notmatch '^[A-Za-z0-9_-]{8,96}$') {
    throw 'Invalid probe_id.'
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\private-transport-e2e-phased'
$statePath = Join-Path $stateRoot ($probeId + '.json')
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "State file missing for probe_id '$probeId'."
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json

$obs = $state.last_observation
$safe = [ordered]@{
    probe_id = $probeId
    stage = [string]$state.stage
    worker_id_present = -not [string]::IsNullOrWhiteSpace([string]$state.worker_id)
    request_file_id_present = -not [string]::IsNullOrWhiteSpace([string]$state.request_file_id)
    request_library_id_present = -not [string]::IsNullOrWhiteSpace([string]$state.request_library_id)
    result_file_id_present = -not [string]::IsNullOrWhiteSpace([string]$state.result_file_id)
    result_library_id_present = -not [string]::IsNullOrWhiteSpace([string]$state.result_library_id)
    before_last_run_present = $null -ne $state.before_last_run
    armed_schedule_present = -not [string]::IsNullOrWhiteSpace([string]$state.armed_schedule)
    last_observation_present = $null -ne $obs
    worker_enabled = if ($null -ne $obs) { [bool]$obs.worker_enabled } else { $false }
    run_advanced = if ($null -ne $obs) { [bool]$obs.run_advanced } else { $false }
    last_run_present = if ($null -ne $obs) { [bool]$obs.last_run_present } else { $false }
    latest_run_http = if ($null -ne $obs) { [int]$obs.latest_run_http } else { 0 }
    result_found = if ($null -ne $obs) { [bool]$obs.result_found } else { $false }
    result_verified = if ($null -ne $obs) { [bool]$obs.result_verified } else { $false }
    result_download_http = if ($null -ne $obs) { [int]$obs.result_download_http } else { 0 }
    error_present = -not [string]::IsNullOrWhiteSpace([string]$state.error)
}

$dir = Split-Path -Parent $GatewayResultPath
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$out = [ordered]@{
    status = 'evidence'
    error = ($safe | ConvertTo-Json -Compress)
    exit_code = 20
}
$out | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 20
