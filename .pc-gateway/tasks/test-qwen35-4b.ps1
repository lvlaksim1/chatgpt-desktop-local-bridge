[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Ollama'
$exe=Join-Path $base 'bin\ollama.exe'
$logs=Join-Path $base 'logs'
$report=[ordered]@{status='failed';stage='preflight';error='';model='qwen3.5:4b';download='not_started';pull_seconds=$null;api_version='';num_gpu=8;num_ctx=1024;response='';tokens=0;tokens_per_second=0;total_seconds=0;log_tail=''}
$start=[DateTime]::UtcNow
try{
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Missing D-drive Ollama executable'}
 $env:OLLAMA_MODELS=Join-Path $base 'models'
 $env:OLLAMA_HOST='127.0.0.1:11434'
 $env:OLLAMA_NO_CLOUD='1'
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 7
 $report.api_version=[string]$v.version
 $report.stage='model_download'
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 10
 $names=@($tags.models|ForEach-Object {[string]$_.name})
 if($names -contains 'qwen3.5:4b'){
  $report.download='already_installed'
 }else{
  $pullStart=[DateTime]::UtcNow
  $outFile=Join-Path $logs 'pull-qwen35-4b.stdout.log'
  $errFile=Join-Path $logs 'pull-qwen35-4b.stderr.log'
  $proc=Start-Process -FilePath $exe -ArgumentList 'pull qwen3.5:4b' -WorkingDirectory (Join-Path $base 'bin') -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  $finished=$proc.WaitForExit(480000)
  if(-not $finished){
   try{$proc.Kill()}catch{}
   throw 'Model pull did not complete within 8 minutes (terminated).'
  }
  $report.pull_seconds=[math]::Round(([DateTime]::UtcNow-$pullStart).TotalSeconds,1)
  $report.download='pull_exit_'+$proc.ExitCode
  if($proc.ExitCode -ne 0){
   $txt=(Get-Content -LiteralPath $errFile -Tail 5|Out-String).Trim()
   if($txt.Length -gt 250){$txt=$txt.Substring($txt.Length-250)}
   throw ('Model download failed: '+$txt)
  }
 }
 $report.stage='generation'
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 10
 $names=@($tags.models|ForEach-Object{[string]$_.name})
 if($names -notcontains 'qwen3.5:4b'){throw 'Downloaded model not registered on server'}
 $payload=@{
  model='qwen3.5:4b'
  prompt='Reply with only the number: what is 2 plus 2?'
  stream=$false
  think=$false
  keep_alive=0
  options=@{num_gpu=8;num_ctx=1024;num_batch=32;num_predict=48;temperature=0}
 }
 $json=ConvertTo-Json -InputObject $payload -Depth 6 -Compress
 $answer=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 120
 if($answer.done -ne $true){throw 'Model returned incomplete response'}
 $report.response=([string]$answer.response).Trim()
 if([string]::IsNullOrWhiteSpace($report.response)){throw 'Model generated no visible response'}
 $report.tokens=[int]$answer.eval_count
 if([double]$answer.eval_duration -gt 0){$report.tokens_per_second=[math]::Round([double]$answer.eval_count*1000000000/[double]$answer.eval_duration,2)}
 $report.status='success'
 $report.stage='done'
 $report.error='qwen3.5:4b answered: '+$report.response+'; GPU layers=8; tokens/s='+$report.tokens_per_second
}catch{
 $report.status='failed'
 $report.error=[string]$_.Exception.Message
 try{
  if($null -ne $_.Exception.Response){
   $reader=New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
   $responseText=$reader.ReadToEnd()
   $reader.Dispose()
   if($responseText){$report.error+='; server='+$responseText}
  }
 }catch{}
}
$report.total_seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
$serverErr=Join-Path $logs 'scheduled-stderr.log'
if(Test-Path -LiteralPath $serverErr -PathType Leaf){
 $report.log_tail=((Get-Content -LiteralPath $serverErr -Tail 15 | Where-Object {$_ -match '(?i)(error|failed|out of memory|cudaMalloc)'}|Select-Object -Last 2)|Out-String).Trim()
}
if($report.status -ne 'success'){$report.error+='; log='+$report.log_tail}
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $logs 'qwen35-4b-test.json') -Encoding UTF8
exit 0
