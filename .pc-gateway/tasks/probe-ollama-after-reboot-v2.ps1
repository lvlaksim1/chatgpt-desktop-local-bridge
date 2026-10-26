[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Ollama'
$exe=Join-Path $base 'bin\ollama.exe'
$models=Join-Path $base 'models'
$logs=Join-Path $base 'logs'
$server=$null
$started=$false
$report=[ordered]@{
    status='failed'
    error=''
    api_version=''
    model=''
    num_gpu=8
    generated_tokens=0
    tokens_per_second=0
    response=''
    server_started=$false
    log_excerpt=''
}
try {
    if(-not (Test-Path $exe)) { throw 'Missing ollama.exe' }
    if(-not (Test-Path $models)) { throw 'Missing model directory' }
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS',$models,'Process')
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Process')
    [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD','1','Process')
    $server=Start-Process -FilePath $exe -ArgumentList 'serve' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'v2-stdout.log') -RedirectStandardError (Join-Path $logs 'v2-stderr.log')
    $started=$true
    $report.server_started=$true
    Start-Sleep -Seconds 6
    $v=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 5
    $report.api_version=[string]$v.version
    $tags=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
    $names=@($tags.models | ForEach-Object { [string]$_.name })
    if($names -notcontains 'qwen3.5:9b') { throw 'Model qwen3.5:9b not registered' }
    $report.model='qwen3.5:9b'
    $payload=ConvertTo-Json -InputObject @{
        model='qwen3.5:9b'
        prompt='Ответь одним словом: два плюс два?'
        stream=$false
        think=$false
        keep_alive=0
        options=@{
            num_ctx=1024
            num_gpu=8
            num_batch=32
            num_predict=24
            temperature=0
        }
    } -Depth 8 -Compress
    $answer=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 75
    if($answer.done -ne $true) { throw 'Generation not completed' }
    if([string]::IsNullOrWhiteSpace([string]$answer.response)) { throw 'Generation returned an empty answer' }
    $report.status='success'
    $report.generated_tokens=[int]$answer.eval_count
    if([double]$answer.eval_duration -gt 0) {
        $report.tokens_per_second=[math]::Round([double]$answer.eval_count * 1000000000 / [double]$answer.eval_duration,2)
    }
    $report.response=([string]$answer.response).Trim()
}
catch {
    $report.status='failed'
    $report.error=[string]$_.Exception.Message
}
if($started -and $null -ne $server) {
    if(-not $server.HasExited) {
        $server.Kill()
        [void]$server.WaitForExit(10000)
    }
}
$stderrPath=Join-Path $logs 'v2-stderr.log'
if(Test-Path $stderrPath) {
    $lastErrors=@(Get-Content -LiteralPath $stderrPath -Tail 100 | Where-Object { $_ -match '(?i)(error|failed|out of memory|cudaMalloc)' } | Select-Object -Last 2)
    $report.log_excerpt=($lastErrors -join ' | ')
}
$summary="$($report.status): $($report.error); api=$($report.api_version); tokens=$($report.generated_tokens); tps=$($report.tokens_per_second); log=$($report.log_excerpt)"
if($summary.Length -gt 700) { $summary=$summary.Substring(0,700) }
$report.error=$summary
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $logs 'reboot-probe-v2-result.json') -Encoding UTF8
exit 0
