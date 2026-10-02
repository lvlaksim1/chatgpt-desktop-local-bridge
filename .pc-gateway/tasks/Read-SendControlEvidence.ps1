[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$EvidenceRequestId='chatgpt-bridge-send-control-diag-r2-20261002144200'
$ledgerRoot=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger'
$ledgerPath=Join-Path $ledgerRoot ($EvidenceRequestId+'.result.json')

function Finish([string]$Status,[int]$Code,[string]$ErrorText=''){
  $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;evidence_request_id=$EvidenceRequestId}
  $dir=Split-Path -Parent $GatewayResultPath
  if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
  $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit $Code
}

try{
  if(-not(Test-Path -LiteralPath $ledgerPath -PathType Leaf)){throw 'Stored gateway evidence was not found.'}
  $stored=Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8|ConvertFrom-Json
  $project=$stored.summary.project_result
  if($null-eq$project){throw 'Stored gateway result does not contain project_result.'}
  if([string]$project.status -ne 'pass'){throw ('Stored diagnostic did not pass: '+[string]$project.error)}

  $safe=[ordered]@{
    adapter_version=$project.adapter_version
    form_found=$project.form_found
    cleared_stale_kind=$project.cleared_stale_kind
    known_controls=$project.known_controls
    buttons=$project.buttons
  }

  # Intentional nonzero evidence return: Repo-PowerShell exposes project error text
  # in the GitHub job log while the underlying stored diagnostic remains untouched.
  Finish 'evidence' 31 ('SEND_CONTROL_EVIDENCE='+($safe|ConvertTo-Json -Depth 8 -Compress))
}catch{
  Finish 'fail' 31 $_.Exception.Message
}
