[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Goose'
$report=[ordered]@{status='failed';error='';alias='qwen3.5:4b-goose';context_tokens=8192;alias_exists=$false;launcher='';api_ok=$false}
try {
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 6
 $report.api_ok=$true
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 8
 $models=@($tags.models|ForEach-Object {[string]$_.name})
 if($models -notcontains 'qwen3.5:4b'){throw 'Base qwen3.5:4b model missing'}
 if($models -notcontains 'qwen3.5:4b-goose'){
  $payload=@{
   model='qwen3.5:4b-goose'
   from='qwen3.5:4b'
   parameters=@{num_ctx=8192}
   stream=$false
  }
  $json=ConvertTo-Json -InputObject $payload -Depth 8 -Compress
  $result=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/create' -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 75
 }
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 8
 $models=@($tags.models|ForEach-Object{[string]$_.name})
 $report.alias_exists=($models -contains 'qwen3.5:4b-goose')
 if(-not $report.alias_exists){throw 'Ollama alias was not registered'}
 $cmd=Join-Path $base 'Goose-Local-4B.cmd'
 $lines=@(
  '@echo off',
  'set "GOOSE_PROVIDER=ollama"',
  'set "GOOSE_MODEL=qwen3.5:4b-goose"',
  'set "OLLAMA_HOST=http://127.0.0.1:11434"',
  'set "GOOSE_DISABLE_KEYRING=1"',
  'set "GOOSE_CONTEXT_LIMIT=8192"',
  'set "GOOSE_INPUT_LIMIT=8192"',
  'set "GOOSE_MODE=approve"',
  'cd /d "D:\LocalAI\Goose\workspace"',
  '"D:\LocalAI\Goose\bin\goose.exe" session --with-builtin developer',
  'pause'
 )
 [IO.File]::WriteAllLines($cmd,$lines,[Text.Encoding]::ASCII)
 $report.launcher=$cmd
 $report.status='success'
 $report.error='Created qwen3.5:4b-goose model with 8192-token context and updated local Goose launcher.'
}catch{$report.error=[string]$_.Exception.Message}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
