[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Ollama'
$launcher=Join-Path $base 'Start-LocalAI-Ollama.ps1'
$logs=Join-Path $base 'logs'
$report=[ordered]@{status='failed';error='';task_registered=$false;task_started=$false;api_reachable=$false;version='';task_name='LocalAI Ollama';task_state='';last_task_result=''}
try{
 if(-not (Test-Path (Join-Path $base 'bin\ollama.exe') -PathType Leaf)){throw 'Ollama executable missing'}
 New-Item -ItemType Directory -Path $logs -Force | Out-Null
 $launcherText=@'
$ErrorActionPreference='Stop'
$logDir='D:\LocalAI\Ollama\logs'
Add-Content -LiteralPath (Join-Path $logDir 'launcher-events.log') -Value ([DateTime]::UtcNow.ToString('o')+' - started from Windows Task Scheduler')
$env:OLLAMA_MODELS='D:\LocalAI\Ollama\models'
$env:OLLAMA_HOST='127.0.0.1:11434'
$env:OLLAMA_NO_CLOUD='1'
$env:OLLAMA_NUM_PARALLEL='1'
$env:OLLAMA_MAX_LOADED_MODELS='1'
try{
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 3
 if($null -ne $v){
  Add-Content -LiteralPath (Join-Path $logDir 'launcher-events.log') -Value 'Ollama already responds; exiting duplicate launcher'
  exit 0
 }
}catch{}
try{
 Set-Location -LiteralPath 'D:\LocalAI\Ollama\bin'
 & 'D:\LocalAI\Ollama\bin\ollama.exe' serve 1>> 'D:\LocalAI\Ollama\logs\scheduled-stdout.log' 2>> 'D:\LocalAI\Ollama\logs\scheduled-stderr.log'
}catch{
 Add-Content -LiteralPath (Join-Path $logDir 'launcher-events.log') -Value ([DateTime]::UtcNow.ToString('o')+' - ERROR '+$_.Exception.Message)
}
'@
 [IO.File]::WriteAllText($launcher,$launcherText,[Text.UTF8Encoding]::new($false))
 $service=New-Object -ComObject 'Schedule.Service'
 $service.Connect()
 $folder=$service.GetFolder('\')
 $definition=$service.NewTask(0)
 $definition.RegistrationInfo.Description='Start local offline Ollama after Windows user login'
 $definition.Settings.Enabled=$true
 $definition.Settings.StartWhenAvailable=$true
 $definition.Settings.AllowDemandStart=$true
 $definition.Settings.ExecutionTimeLimit='PT0S'
 $definition.Settings.MultipleInstances=2
 $definition.Settings.DisallowStartIfOnBatteries=$false
 $definition.Settings.StopIfGoingOnBatteries=$false
 $user=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
 $definition.Principal.UserId=$user
 $definition.Principal.LogonType=3
 $definition.Principal.RunLevel=0
 $trigger=$definition.Triggers.Create(9)
 $trigger.UserId=$user
 $action=$definition.Actions.Create(0)
 $action.Path=Join-Path $PSHOME 'powershell.exe'
 $action.Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "D:\LocalAI\Ollama\Start-LocalAI-Ollama.ps1"'
 $action.WorkingDirectory=Join-Path $base 'bin'
 $task=$folder.RegisterTaskDefinition('LocalAI Ollama',$definition,6,$user,$null,3,$null)
 $report.task_registered=$true
 # Delete only the shortcut created by our previous deployment; Scheduler now replaces it.
 $shortcut=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'LocalAI Ollama.lnk'
 if(Test-Path -LiteralPath $shortcut -PathType Leaf){Remove-Item -LiteralPath $shortcut -Force}
 $running=$task.Run($null)
 $report.task_started=($null -ne $running)
 for($i=0;$i -lt 15;$i++){
  Start-Sleep -Seconds 1
  try{
   $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 2
   $report.api_reachable=$true
   $report.version=[string]$v.version
   break
  }catch{}
 }
 $report.task_state=[string]$task.State
 $report.last_task_result=[string]$task.LastTaskResult
 if($report.api_reachable){
  $report.status='success'
  $report.error='Windows Scheduled Task registered, started, and Ollama API responded: '+$report.version
 }else{
  $report.error='Scheduler registered and run requested but API not reachable in 15 seconds. Task state='+$report.task_state+'; last result='+$report.last_task_result
 }
}catch{$report.error=[string]$_.Exception.Message}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
