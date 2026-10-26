[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Ollama'
$exe=Join-Path $base 'bin\ollama.exe'
$logs=Join-Path $base 'logs'
$launch=Join-Path $base 'Start-LocalAI-Ollama.ps1'
$report=[ordered]@{status='failed';error='';startup_shortcut='';launcher_path=$launch;api_reachable=$false;api_version='';started_process_id=$null;started_at=[DateTime]::UtcNow.ToString('o')}
try{
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Ollama executable missing on D'}
 if(-not (Test-Path -LiteralPath (Join-Path $base 'models') -PathType Container)){throw 'Model directory missing on D'}
 New-Item -ItemType Directory -Force -Path $logs | Out-Null
 $launchText=@'
$ErrorActionPreference='Stop'
$env:OLLAMA_MODELS='D:\LocalAI\Ollama\models'
$env:OLLAMA_HOST='127.0.0.1:11434'
$env:OLLAMA_NO_CLOUD='1'
$env:OLLAMA_NUM_PARALLEL='1'
$env:OLLAMA_MAX_LOADED_MODELS='1'
$api='http://127.0.0.1:11434/api/version'
try{
 $v=Invoke-RestMethod -Uri $api -Method Get -TimeoutSec 3
 if($null -ne $v){exit 0}
}catch{}
Set-Location -LiteralPath 'D:\LocalAI\Ollama\bin'
& 'D:\LocalAI\Ollama\bin\ollama.exe' serve 1>> 'D:\LocalAI\Ollama\logs\persistent-stdout.log' 2>> 'D:\LocalAI\Ollama\logs\persistent-stderr.log'
'@
 [IO.File]::WriteAllText($launch,$launchText,[Text.UTF8Encoding]::new($false))
 $startup=[Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
 if([string]::IsNullOrWhiteSpace($startup)){throw 'Windows user Startup directory unavailable'}
 $shortcutPath=Join-Path $startup 'LocalAI Ollama.lnk'
 $shell=New-Object -ComObject WScript.Shell
 $shortcut=$shell.CreateShortcut($shortcutPath)
 $shortcut.TargetPath=Join-Path $PSHOME 'powershell.exe'
 $shortcut.Arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "D:\LocalAI\Ollama\Start-LocalAI-Ollama.ps1"'
 $shortcut.WorkingDirectory=Join-Path $base 'bin'
 $shortcut.WindowStyle=7
 $shortcut.Description='Run local-only Ollama server on Windows login'
 $shortcut.Save()
 $report.startup_shortcut=$shortcutPath
 $live=$false
 try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 3;$live=$true}catch{}
 if(-not $live){
  $oldTracking=[Environment]::GetEnvironmentVariable('RUNNER_TRACKING_ID','Process')
  [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID',$null,'Process')
  try{
   $args=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+$launch+'"'))
   $child=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -WorkingDirectory (Join-Path $base 'bin') -WindowStyle Hidden -PassThru
   $report.started_process_id=[int]$child.Id
  } finally {
   [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID',$oldTracking,'Process')
  }
  for($i=0;$i -lt 20;$i++){
   Start-Sleep -Seconds 1
   try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 2;$live=$true;break}catch{}
  }
 }
 $report.api_reachable=$live
 if(-not $live){throw 'Ollama API did not become available within 20 seconds'}
 $report.api_version=[string]$v.version
 $report.status='success'
 $report.error='Ollama local API reachable, persistent launcher on D and Windows user Startup shortcut installed.'
}catch{
 $report.error=[string]$_.Exception.Message
}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
