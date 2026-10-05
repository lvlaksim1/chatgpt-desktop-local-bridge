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

$safe=[ordered]@{
    target_request_id=$target
    gateway_status=[string]$payload.status
    project_status=[string]$project.status
    project_exit_code=[int]$project.exit_code
}

if($null-ne$project.PSObject.Properties['evidence']){
    $ev=$project.evidence
    $safe.evidence=[ordered]@{
        worker_count=[int]$ev.worker_count
        request_found=[bool]$ev.request_found
        result_found=[bool]$ev.result_found
        result_verified=[bool]$ev.result_verified
        request_message_id_present=[bool]$ev.request_message_id_present
        cleanup_count=[int]$ev.cleanup_count
        cleanup_all=[bool]$ev.cleanup_all
        workers=@($ev.workers)
    }
}

$dir=Split-Path -Parent $GatewayResultPath
if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
$out=[ordered]@{
    status='evidence'
    error=($safe|ConvertTo-Json -Depth 20 -Compress)
    exit_code=20
}
$out|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 20
