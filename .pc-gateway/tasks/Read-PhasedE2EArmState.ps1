[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$probeId=[string]$request.args.probe_id
if([string]::IsNullOrWhiteSpace($probeId) -or $probeId -notmatch '^[A-Za-z0-9_-]{8,96}$'){
    throw 'Invalid probe_id.'
}

$stateRoot=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\private-transport-e2e-phased'
$statePath=Join-Path $stateRoot ($probeId+'.json')
if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){
    throw "State file missing for probe_id '$probeId'."
}

$s=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
$safe=[ordered]@{
    probe_id=$probeId
    stage=[string]$s.stage
    armed_schedule=[string]$s.armed_schedule
    armed_timing_mode=[string]$s.armed_timing_mode
    armed_target_time_utc_present=[bool]$s.armed_target_time_utc_present
    armed_next_run_count=[int]$s.armed_next_run_count
    armed_future_next_run_count=[int]$s.armed_future_next_run_count
    armed_first_future_delta_sec=if($null-ne$s.armed_first_future_delta_sec){[int]$s.armed_first_future_delta_sec}else{$null}
    phase_a_completed_utc=[string]$s.phase_a_completed_utc
    request_file_id_present=-not[string]::IsNullOrWhiteSpace([string]$s.request_file_id)
    request_library_id_present=-not[string]::IsNullOrWhiteSpace([string]$s.request_library_id)
    error_present=-not[string]::IsNullOrWhiteSpace([string]$s.error)
}

$dir=Split-Path -Parent $GatewayResultPath
if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
$out=[ordered]@{
    status='evidence'
    error=($safe|ConvertTo-Json -Compress)
    exit_code=20
}
$out|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 20
