[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$base='D:\LocalAI\Ollama'
$binary=Join-Path $base 'bin\ollama.exe'
$models=Join-Path $base 'models'
$log=Join-Path $base 'logs\server.stderr.log'
$report=[ordered]@{
 status='diagnostic'
 error=''
 utc=[DateTime]::UtcNow.ToString('o')
 binary_exists=$false
 model_manifest_exists=$false
 models_dir_exists=$false
 model_blobs_count=0
 server_process_count=0
 api_reachable=$false
 api_version=''
 models_available=@()
 server_log_utc=''
}
try {
  $report.binary_exists=Test-Path -LiteralPath $binary -PathType Leaf
  $report.models_dir_exists=Test-Path -LiteralPath $models -PathType Container
  $report.model_manifest_exists=Test-Path -LiteralPath (Join-Path $models 'manifests\registry.ollama.ai\library\qwen3.5\9b') -PathType Leaf
  if(Test-Path -LiteralPath (Join-Path $models 'blobs') -PathType Container){
   $report.model_blobs_count=@(Get-ChildItem -LiteralPath (Join-Path $models 'blobs') -File).Count
  }
  $report.server_process_count=@(Get-Process -Name 'ollama','llama-server' -ErrorAction SilentlyContinue).Count
  if(Test-Path -LiteralPath $log -PathType Leaf){
   $report.server_log_utc=(Get-Item -LiteralPath $log).LastWriteTimeUtc.ToString('o')
  }
  try {
   $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 4 -Method Get -ErrorAction Stop
   $report.api_reachable=$true
   $report.api_version=[string]$v.version
   $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 4 -Method Get -ErrorAction Stop
   $report.models_available=@($tags.models | ForEach-Object { [string]$_.name })
  }
  catch {
    $report.api_error=[string]$_.Exception.Message
  }
  $report.error="Binary=$($report.binary_exists); model_manifest=$($report.model_manifest_exists); blobs=$($report.model_blobs_count); process_count=$($report.server_process_count); API=$($report.api_reachable); version=$($report.api_version); models=$($report.models_available -join ','); server_log_utc=$($report.server_log_utc)"
  $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host "LLM_POST_REBOOT_STATUS=$($report.error)"
  exit 0
} catch {
  $report.status='failed'
  $report.error=([string]$_.Exception.Message)
  $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 1
}
