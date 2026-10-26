[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$base='D:\LocalAI\Ollama'
$exe=Join-Path $base 'bin\ollama.exe'
$models=Join-Path $base 'models'
$logDir=Join-Path $base 'logs'
$api='http://127.0.0.1:11434'
$server=$null
$startedServer=$false
$report=[ordered]@{
 status='failed'
 error=''
 stage='preflight'
 started_utc=[DateTime]::UtcNow.ToString('o')
 server_was_started=$false
 api_version=''
 installed_model=$false
 attempts=@()
 success_profile=$null
}
function LastFailure([string]$msg) {
 if([string]::IsNullOrWhiteSpace($msg)){return 'Unknown error'}
 if($msg.Length -gt 280){return $msg.Substring(0,280)}
 return $msg
}
function Save-Result {
 $report.completed_utc=[DateTime]::UtcNow.ToString('o')
 $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
 if(Test-Path $logDir){
  $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $logDir 'reboot-probe-result.json') -Encoding UTF8
 }
 Write-Host ("LLM_REBOOT_PROBE=$($report.status); $($report.error)")
}
try {
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'ollama.exe not found on D'}
 if(-not (Test-Path -LiteralPath $models -PathType Container)){throw 'Ollama model directory not found on D'}
 New-Item -ItemType Directory -Path $logDir -Force | Out-Null
 [Environment]::SetEnvironmentVariable('OLLAMA_MODELS',$models,'Process')
 [Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Process')
 [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD','1','Process')
 [Environment]::SetEnvironmentVariable('OLLAMA_NUM_PARALLEL','1','Process')
 [Environment]::SetEnvironmentVariable('OLLAMA_MAX_LOADED_MODELS','1','Process')
 $report.stage='starting'
 $reachable=$false
 try {
  $v=Invoke-RestMethod -Uri ($api+'/api/version') -Method Get -TimeoutSec 2
  $reachable=$true
 } catch {}
 if(-not $reachable){
  $server=Start-Process -FilePath $exe -ArgumentList 'serve' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir 'reboot-probe-stdout.log') -RedirectStandardError (Join-Path $logDir 'reboot-probe-stderr.log')
  $startedServer=$true
  $report.server_was_started=$true
  for($i=0;$i -lt 24;$i++){
   Start-Sleep -Seconds 1
   try {
    $v=Invoke-RestMethod -Uri ($api+'/api/version') -Method Get -TimeoutSec 2
    $reachable=$true
    break
   } catch {}
   if($server.HasExited){break}
  }
 }
 if(-not $reachable){throw 'Ollama API did not become available within 24 seconds.'}
 $report.api_version=[string]$v.version
 $report.stage='model-check'
 $tags=Invoke-RestMethod -Uri ($api+'/api/tags') -Method Get -TimeoutSec 8
 $found=@($tags.models|Where-Object {[string]$_.name -eq 'qwen3.5:9b'})
 if($found.Count -ne 1){throw 'Model qwen3.5:9b not registered (nothing was downloaded).'}
 $report.installed_model=$true
 $report.stage='generation'
 $attempts=New-Object System.Collections.ArrayList
 foreach($layers in @(8,0)){
  $trial=[ordered]@{num_gpu=$layers;status='failed';seconds=0;error=''}
  $start=[DateTime]::UtcNow
  $payload=@{
    model='qwen3.5:9b'
    prompt='Ответь одним словом: два плюс два?'
    stream=$false
    think=$false
    keep_alive=0
    options=@{
      num_gpu=$layers
      num_ctx=1024
      num_batch=32
      num_predict=20
      temperature=0
    }
  }|ConvertTo-Json -Compress -Depth 8
  try {
    $a=Invoke-RestMethod -Uri ($api+'/api/generate') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 90
    $trial.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2)
    if($a.done -ne $true -or [string]::IsNullOrWhiteSpace([string]$a.response)){throw 'No completed nonempty response returned'}
    $trial.status='success'
    $trial.tokens=[int]$a.eval_count
    $trial.tokens_per_sec=if([double]$a.eval_duration -gt 0){[math]::Round([double]$a.eval_count * 1e9 / [double]$a.eval_duration,2)}else{0}
    $trial.response=([string]$a.response).Trim()
    [void]$attempts.Add($trial)
    $report.success_profile=$layers
    $report.status='success'
    $report.error="Qwen3.5:9b responded; num_gpu=$layers; tps=$($trial.tokens_per_sec); seconds=$($trial.seconds)"
    break
  } catch {
    $trial.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2)
    $message=[string]$_.Exception.Message
    try {
      $r=$_.Exception.Response
      if($null -ne $r){
       $reader=New-Object IO.StreamReader($r.GetResponseStream())
       $txt=$reader.ReadToEnd()
       $reader.Dispose()
       if($txt){$message += ('; server: '+$txt)}
      }
    } catch {}
    $trial.error=LastFailure $message
    [void]$attempts.Add($trial)
    Write-Host ("LLM_TRIAL_FAILED num_gpu=$layers error=$($trial.error)")
  }
 }
 $report.attempts=@($attempts.ToArray())
 if($report.status -ne 'success'){
  $failures=@($report.attempts|ForEach-Object{"$($_.num_gpu):$($_.error)"})
  $report.error=LastFailure ($failures -join ' | ')
  $report.stage='failed-generation'
 } else {$report.stage='completed'}
}catch{
 $report.status='failed'
 $report.error=LastFailure ([string]$_.Exception.Message)
}
finally{
 if($startedServer -and $null -ne $server){
  try{
    if(-not $server.HasExited){
      $server.Kill()
      [void]$server.WaitForExit(10000)
    }
  }catch{}
 }
 Save-Result
}
# A diagnostic failure still completes the gateway request, with error details in the project result.
exit 0
