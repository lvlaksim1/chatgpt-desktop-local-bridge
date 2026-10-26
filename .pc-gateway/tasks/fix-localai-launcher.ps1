[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Ollama'
$launcher=Join-Path $root 'Start-LocalAI-Ollama.ps1'
$report=[ordered]@{status='failed';error='';task_exists=$false;task_state='';task_last_result='';api_reachable=$false;version='';processes=0}
try{
 if(-not (Test-Path (Join-Path $root 'bin\ollama.exe') -PathType Leaf)){throw 'Ollama binary not found'}
 $text=@'
$ErrorActionPreference='Stop'
$logs='D:\LocalAI\Ollama\logs'
$env:OLLAMA_MODELS='D:\LocalAI\Ollama\models'
$env:OLLAMA_HOST='127.0.0.1:11434'
$env:OLLAMA_NO_CLOUD='1'
$env:OLLAMA_NUM_PARALLEL='1'
$env:OLLAMA_MAX_LOADED_MODELS='1'
Add-Content -LiteralPath (Join-Path $logs 'launcher-events.log') -Value ([DateTime]::UtcNow.ToString('o')+' - launcher entered')
try{
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 2
 if($null -ne $v){exit 0}
}catch{}
try{
 $p=Start-Process -FilePath 'D:\LocalAI\Ollama\bin\ollama.exe' -ArgumentList 'serve' -WorkingDirectory 'D:\LocalAI\Ollama\bin' -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $logs 'scheduled-stdout.log') -RedirectStandardError (Join-Path $logs 'scheduled-stderr.log')
 Add-Content -LiteralPath (Join-Path $logs 'launcher-events.log') -Value ([DateTime]::UtcNow.ToString('o')+' - Ollama exited: '+$p.ExitCode)
}catch{
 Add-Content -LiteralPath (Join-Path $logs 'launcher-events.log') -Value ([DateTime]::UtcNow.ToString('o')+' - START_FAILURE '+$_.Exception.Message)
}
'@
 [IO.File]::WriteAllText($launcher,$text,[Text.UTF8Encoding]::new($false))
 $service=New-Object -ComObject 'Schedule.Service'
 $service.Connect()
 $task=$service.GetFolder('\').GetTask('LocalAI Ollama')
 $report.task_exists=($null -ne $task)
 $running=$false
 try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 3;$running=$true}catch{}
 if(-not $running){$null=$task.Run($null)}
 for($i=0;$i -lt 18;$i++){
  if($running){break}
  Start-Sleep -Seconds 1
  try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2;$running=$true;break}catch{}
 }
 $report.api_reachable=$running
 if($running){$report.version=[string]$v.version}
 $report.task_state=[string]$task.State
 $report.task_last_result=[string]$task.LastTaskResult
 $report.processes=@(Get-Process -Name 'ollama','llama-server' -ErrorAction SilentlyContinue).Count
 if($running){$report.status='success';$report.error='Ollama responds at 127.0.0.1:11434; Scheduled Task startup stable at check time; server version '+$report.version}
 else{$report.error='Ollama still unreachable; task_state='+$report.task_state+'; task_last_result='+$report.task_last_result+'; processes='+$report.processes}
}catch{$report.error=[string]$_.Exception.Message}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
