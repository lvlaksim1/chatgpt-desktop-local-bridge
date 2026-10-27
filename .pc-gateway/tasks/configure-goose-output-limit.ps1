[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$report=[ordered]@{status='failed';error='';alias='qwen3.5:4b-goose';num_ctx=8192;num_predict=-1;registered=$false;parameters=''}
try{
 $null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 6
 $model=@{
  model='qwen3.5:4b-goose'
  from='qwen3.5:4b'
  parameters=@{num_ctx=8192;num_predict=-1}
  stream=$false
 }
 $payload=ConvertTo-Json -InputObject $model -Depth 7 -Compress
 $result=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/create' -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 60
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 8
 $names=@($tags.models|ForEach-Object{[string]$_.name})
 $report.registered=($names -contains 'qwen3.5:4b-goose')
 if(-not $report.registered){throw 'Goose model missing after update'}
 $body=ConvertTo-Json -InputObject @{model='qwen3.5:4b-goose'} -Compress
 $show=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/show' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 8
 $report.parameters=[string]$show.parameters
 if($report.parameters -notmatch '(?m)num_predict\s+-1'){throw 'num_predict was not persisted into model defaults'}
 $report.status='success'
 $report.error='Goose-only model updated with default num_ctx=8192 and num_predict=-1; original models untouched.'
}catch{$report.error=[string]$_.Exception.Message}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
