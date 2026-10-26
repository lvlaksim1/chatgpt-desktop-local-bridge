[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$base='D:\LocalAI\Ollama'
$report=[ordered]@{status='failed';error='';phase='preflight';attempts=@();chosen_gpu_layers=$null;benchmark_tps=$null; started_utc=[datetime]::UtcNow.ToString('o')}
function WriteResult([string]$state,[string]$explanation) {
 $report.status=$state
 $report.error=$explanation
 $report.finished_utc=[datetime]::UtcNow.ToString('o')
 $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $base 'logs\mmap-test-result.json') -Encoding UTF8
 $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
}
function ExtractError([System.Management.Automation.ErrorRecord]$record) {
 $msg=[string]$record.Exception.Message
 $r=$record.Exception.Response
 if ($null -ne $r) {
   try {
     $s=$r.GetResponseStream()
     if($null -ne $s){
       $reader=New-Object IO.StreamReader($s)
       $body=$reader.ReadToEnd()
       if($body){$msg+=" RESPONSE: "+$body}
     }
   }catch {}
 }
 $msg=$msg -replace '\s+',' '
 if($msg.Length -gt 950){$msg=$msg.Substring(0,950)}
 return $msg
}
try {
 if(-not(Test-Path -LiteralPath (Join-Path $base 'bin\ollama.exe') -PathType Leaf)){throw 'Ollama executable unavailable'}
 if(-not(Test-Path -LiteralPath (Join-Path $base 'models') -PathType Container)){throw 'Model dir unavailable'}
 $api='http://127.0.0.1:11434'
 [Environment]::SetEnvironmentVariable('OLLAMA_MODELS',(Join-Path $base 'models'),'Process')
 [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD','1','Process')
 $ver=Invoke-RestMethod -Uri ($api+'/api/version') -Method Get -TimeoutSec 8
 $report.server_version=[string]$ver.version
 $tags=Invoke-RestMethod -Uri ($api+'/api/tags') -Method Get -TimeoutSec 8
 if(@($tags.models|Where-Object { [string]$_.name -eq 'qwen3.5:9b' }).Count -ne 1){throw 'Model not installed; do not download'}
 $report.phase='generate'
 foreach($layers in @(8,0)) {
   $req=@{
     model='qwen3.5:9b'
     prompt='Reply with exactly one word: OK'
     stream=$false
     think=$false
     keep_alive='0'
     options=@{
       num_gpu=$layers
       use_mmap=$true
       num_ctx=2048
       num_batch=16
       num_predict=12
       temperature=0
     }
   }|ConvertTo-Json -Depth 8 -Compress
   $entry=[ordered]@{num_gpu=$layers;status='failed';error='';response='';generation_tps=$null}
   Write-Host ("MODEL_MMAP_BEGIN num_gpu="+$layers)
   try{
     $r=Invoke-RestMethod -Uri ($api+'/api/generate') -Method Post -ContentType 'application/json' -Body $req -TimeoutSec 85
     if($null -eq $r -or $r.done -ne $true -or [string]::IsNullOrWhiteSpace([string]$r.response)){
       throw 'No completed text response from generation endpoint'
     }
     $entry.status='success'
     $entry.response=([string]$r.response).Trim()
     $entry.generation_tps=if([double]$r.eval_duration -gt 0){[math]::Round(([double]$r.eval_count*1e9/[double]$r.eval_duration),2)} else {0}
     $entry.tokens=[int]$r.eval_count
     $report.attempts+=@($entry)
     $report.chosen_gpu_layers=$layers
     $report.benchmark_tps=$entry.generation_tps
     $report.phase='complete'
     WriteResult ("success: mmap GPU layers=$layers TPS=$($entry.generation_tps)") ''
     exit 0
   }catch{
     $entry.error=ExtractError $_
     $report.attempts+=@($entry)
     Write-Host ("MODEL_MMAP_FAILED num_gpu="+$layers+" error="+$entry.error)
   }
 }
 $failures=@($report.attempts|ForEach-Object{"GPU=$($_.num_gpu): $($_.error)"})
 $message=$failures -join ' || '
 if($message.Length -gt 680){$message=$message.Substring(0,680)}
 WriteResult 'failed' $message
 exit 1
}catch{
 $message=ExtractError $_
 WriteResult 'failed' $message
 exit 1
}
