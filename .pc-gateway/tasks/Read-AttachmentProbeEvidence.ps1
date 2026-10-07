[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
function Finish([string]$s,[int]$c,[string]$e,[hashtable]$x){$o=[ordered]@{status=$s;exit_code=$c;error=$e};foreach($k in $x.Keys){$o[$k]=$x[$k]};$d=Split-Path -Parent $GatewayResultPath;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null};$o|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8;exit $c}
try{
  $req=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
  $target=[string]$req.args.target_request_id
  if([string]::IsNullOrWhiteSpace($target)){throw 'target_request_id_missing'}
  if($target -notmatch '^[A-Za-z0-9._-]{1,160}$'){throw 'target_request_id_invalid'}
  $root=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence'
  $dir=Join-Path $root $target
  $project=Join-Path $dir 'project-result.json'
  $stdout=Join-Path $dir 'task-stdout.log'
  $stderr=Join-Path $dir 'task-stderr.log'
  if(-not(Test-Path -LiteralPath $project -PathType Leaf)){throw 'project_result_missing'}
  $payload=Get-Content -LiteralPath $project -Raw -Encoding UTF8|ConvertFrom-Json
  $outText=''; if(Test-Path -LiteralPath $stdout -PathType Leaf){$outText=Get-Content -LiteralPath $stdout -Raw -Encoding UTF8}
  $errText=''; if(Test-Path -LiteralPath $stderr -PathType Leaf){$errText=Get-Content -LiteralPath $stderr -Raw -Encoding UTF8}
  Finish 'pass' 0 '' @{target_request_id=$target;project_result=$payload;stdout=$outText;stderr=$errText}
}catch{Finish 'fail' 40 $_.Exception.Message @{}}
