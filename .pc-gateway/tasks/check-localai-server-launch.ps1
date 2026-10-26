[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$base='D:\LocalAI\Ollama'
$log=Join-Path $base 'logs\persistent-stderr.log'
$launcher=Join-Path $base 'Start-LocalAI-Ollama.ps1'
$startup=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'LocalAI Ollama.lnk'
$report=@{status='diagnostic';error='';launcher_exists=(Test-Path -LiteralPath $launcher);startup_exists=(Test-Path -LiteralPath $startup);server_log_exists=(Test-Path -LiteralPath $log);server_tail='';api_ok=$false;processes=@()}
$report.processes=@(Get-Process -Name 'ollama','llama-server' -ErrorAction SilentlyContinue|ForEach-Object{$_.ProcessName+':'+$_.Id})
try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 3;$report.api_ok=$true;$report.api_version=$v.version}catch{}
if($report.server_log_exists){
 $tail=@(Get-Content -LiteralPath $log -Tail 25 -ErrorAction SilentlyContinue)
 $report.server_tail=($tail -join ' | ')
}
$report.error='startup='+$report.startup_exists+' launcher='+$report.launcher_exists+' server_log='+$report.server_log_exists+' API='+$report.api_ok+' processes='+($report.processes -join ',')+' tail='+$report.server_tail
if($report.error.Length -gt 700){$report.error=$report.error.Substring($report.error.Length-700)}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
