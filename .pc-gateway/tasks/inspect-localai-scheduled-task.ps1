[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$base='D:\LocalAI\Ollama'
$report=[ordered]@{status='diagnostic';error='';task_state='';last_result='';last_run_time='';task_user='';logs=@();process_count=0;api_reachable=$false}
try{
 $svc=New-Object -ComObject 'Schedule.Service'
 $svc.Connect()
 $task=$svc.GetFolder('\').GetTask('LocalAI Ollama')
 $report.task_state=[string]$task.State
 $report.last_result=[string]$task.LastTaskResult
 $report.last_run_time=[string]$task.LastRunTime
 $report.task_user=[string]$task.Definition.Principal.UserId
}catch{$report.error='TaskScheduler error: '+$_.Exception.Message}
foreach($fn in @('launcher-events.log','scheduled-stderr.log','scheduled-stdout.log','persistent-stderr.log')){
 $p=Join-Path (Join-Path $base 'logs') $fn
 if(Test-Path -LiteralPath $p -PathType Leaf){
  $f=Get-Item -LiteralPath $p
  $tail=((Get-Content -LiteralPath $p -Tail 8 -ErrorAction SilentlyContinue|Out-String).Trim())
  $report.logs+=($fn+' bytes='+$f.Length+' tail='+$tail)
 }
}
$report.process_count=@(Get-Process -Name 'ollama','llama-server' -ErrorAction SilentlyContinue).Count
try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 3;$report.api_reachable=$true}catch{}
$report.error='task_state='+$report.task_state+' last='+$report.last_result+' last_run='+$report.last_run_time+' api='+$report.api_reachable+' processes='+$report.process_count+' logs='+($report.logs -join ' || ')
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
