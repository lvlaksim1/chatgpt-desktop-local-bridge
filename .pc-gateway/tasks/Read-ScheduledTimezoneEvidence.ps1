[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$target=[string]$request.args.target_request_id
if([string]::IsNullOrWhiteSpace($target) -or $target -notmatch '^[A-Za-z0-9._-]{1,200}$'){
    throw 'Invalid target_request_id.'
}

$ledgerRoot=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger'
$completed=Join-Path $ledgerRoot ($target+'.result.json')
if(-not(Test-Path -LiteralPath $completed -PathType Leaf)){
    throw "Completed gateway ledger missing for $target"
}

$payload=Get-Content -LiteralPath $completed -Raw -Encoding UTF8|ConvertFrom-Json
$project=$payload.summary.project_result
if($null-eq$project){throw 'project_result missing'}
if($null-eq$project.PSObject.Properties['evidence']){throw 'project evidence missing'}

$ev=$project.evidence
$safe=[ordered]@{
    target_request_id=$target
    gateway_status=[string]$payload.status
    project_status=[string]$project.status
    counts=$ev.counts
    phase_worker=[ordered]@{
        found_in_lists=[bool]$ev.phase_worker.found_in_lists
        list_source=[string]$ev.phase_worker.list_source
        current=$ev.phase_worker.current
        armed_schedule=$ev.phase_worker.armed_schedule
        before_last_run_present=[bool]$ev.phase_worker.before_last_run_present
    }
    comparator=$ev.comparator
    daily_z_reference=$ev.daily_z_reference
}

$compact=$safe|ConvertTo-Json -Depth 20 -Compress
if($compact.Length -gt 6000){throw 'timezone evidence unexpectedly large'}

$dir=Split-Path -Parent $GatewayResultPath
if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
$out=[ordered]@{
    status='evidence'
    error=$compact
    exit_code=20
}
$out|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 20
