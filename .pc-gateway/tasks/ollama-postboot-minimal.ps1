param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Continue'
$base='D:\LocalAI\Ollama'
$exe=Join-Path $base 'bin\ollama.exe'
$logs=Join-Path $base 'logs'
$models=Join-Path $base 'models'
$report=@{status='failed';error='not run';api='';response='';tokens=0;tps=0;server_started=$false;log_excerpt=''}
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$env:OLLAMA_MODELS=$models
$env:OLLAMA_HOST='127.0.0.1:11434'
$env:OLLAMA_NO_CLOUD='1'
$server=$null
if(Test-Path -LiteralPath $exe -PathType Leaf) {
 $server=Start-Process -FilePath $exe -ArgumentList 'serve' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'minimal-stdout.log') -RedirectStandardError (Join-Path $logs 'minimal-stderr.log') -ErrorAction SilentlyContinue
}
if($null -ne $server){$report.server_started=$true}
Start-Sleep -Seconds 6
$v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 4 -ErrorAction SilentlyContinue
if($null -ne $v){$report.api=[string]$v.version}
$json='{"model":"qwen3.5:9b","prompt":"What is 2+2? Reply with one number.","stream":false,"think":false,"keep_alive":0,"options":{"num_ctx":1024,"num_gpu":8,"num_batch":32,"num_predict":24,"temperature":0}}'
$apiErrors=@()
$response=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 75 -ErrorAction SilentlyContinue -ErrorVariable +apiErrors
if($null -ne $response -and $response.done -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$response.response)) {
 $report.status='success'
 $report.response=[string]$response.response
 $report.tokens=[int]$response.eval_count
 if([double]$response.eval_duration -gt 0){$report.tps=[math]::Round(([double]$response.eval_count*1000000000)/[double]$response.eval_duration,2)}
 $report.error="Generation completed. $($report.tokens) tokens at $($report.tps) tokens/second."
}
else {$report.error="Generation failed; API errors: "+([string]($apiErrors|Out-String)).Trim()}
if($null -ne $server -and -not $server.HasExited){$server.Kill()}
$logpath=Join-Path $logs 'minimal-stderr.log'
if(Test-Path $logpath){
 $lines=@(Get-Content -LiteralPath $logpath -Tail 60 | Where-Object {$_ -match '(?i)(error|failed|out of memory|cudaMalloc)'} | Select-Object -Last 2)
 $report.log_excerpt=($lines -join ' | ')
}
if($report.status -ne 'success'){$report.error=([string]$report.error+" "+[string]$report.log_excerpt).Trim()}
if($report.error.Length -gt 650){$report.error=$report.error.Substring(0,650)}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $logs 'minimal-probe-result.json') -Encoding UTF8
exit 0
