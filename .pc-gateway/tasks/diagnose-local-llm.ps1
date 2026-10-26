[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$base='D:\LocalAI\Ollama'
$log=Join-Path $base 'logs\server.stderr.log'
$diagnostics=[ordered]@{
 status='diagnostic'
 error=''
 checked_utc=[datetime]::UtcNow.ToString('o')
 server=''
 models=''
 server_log_modified=''
 server_log_size=0
 related_errors=@()
 processes=@()
 gpu=''
}
try {
  $models=Join-Path $base 'models'
  [Environment]::SetEnvironmentVariable('OLLAMA_MODELS',$models,'Process')
  [Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Process')
  [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD','1','Process')
  try {
    $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 8
    $diagnostics.server=[string]$v.version
    $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 8
    $diagnostics.models=(@($tags.models|ForEach-Object {[string]$_.name}) -join ', ')
  } catch { $diagnostics.server="API_ERROR: $($_.Exception.Message)" }
  $ollamaProcesses=@(Get-CimInstance Win32_Process -Filter "Name='ollama.exe' OR Name='llama-server.exe'" -ErrorAction SilentlyContinue)
  $diagnostics.processes=@($ollamaProcesses|ForEach-Object {
    "{0} pid={1} parent={2}" -f [string]$_.Name,[string]$_.ProcessId,[string]$_.ParentProcessId
  })
  if (Test-Path -LiteralPath $log -PathType Leaf) {
    $f=Get-Item -LiteralPath $log
    $diagnostics.server_log_modified=$f.LastWriteTimeUtc.ToString('o')
    $diagnostics.server_log_size=[long]$f.Length
    $lines=@(Get-Content -LiteralPath $log -Tail 1000 -ErrorAction Stop)
    $wanted=@($lines|Where-Object{
      $_ -match '(?i)(level=ERROR|level=WARN|cudaMalloc failed|out of memory|failed to allocate|error loading model|Load failed|unable to allocate|model loading error|terminated|runner crash|cannot allocate|failed to load|slot unavailable|500 Internal)'
    })
    $diagnostics.related_errors=@($wanted|Select-Object -Last 12|ForEach-Object {
      $s=[string]$_
      $s=$s -replace 'D:\\LocalAI\\Ollama\\models\\blobs\\sha256-[a-f0-9]+','MODEL_BLOB'
      if($s.Length -gt 380) {$s=$s.Substring(0,380)}
      $s
    })
  } else { $diagnostics.related_errors=@('server.stderr.log missing') }
  try {
    $g=& nvidia-smi.exe '--query-gpu=name,memory.total,memory.used,memory.free' '--format=csv,noheader,nounits' 2>$null
    $diagnostics.gpu=($g|Out-String).Trim()
  } catch {$diagnostics.gpu="nvidia-smi unavailable"}
  $short=@($diagnostics.related_errors | Select-Object -Last 4|ForEach-Object { ([string]$_ -replace '\s+',' ').Trim() })
  $diagnostics.error="Ollama=$($diagnostics.server); gpu=$($diagnostics.gpu); lastLog=$($diagnostics.server_log_modified); relevant: "+($short -join ' || ')
  if ($diagnostics.error.Length -gt 650) { $diagnostics.error=$diagnostics.error.Substring(0,650) }
  $out=Join-Path $base 'logs\diagnostic-result.json'
  $diagnostics | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
  $diagnostics | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host "LOCAL_LLM_DIAGNOSTIC_COMPLETE"
  exit 0
} catch {
  $diagnostics.status='failed'
  $diagnostics.error=([string]$_.Exception.Message)
  $diagnostics|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 1
}
