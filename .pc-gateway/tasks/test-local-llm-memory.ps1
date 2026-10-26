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
$logs=Join-Path $base 'logs'
$api='http://127.0.0.1:11434'
$model='qwen3.5:9b'
$alias='qwen3.5:9b-rtx2070'
$stage='preflight'
$report=[ordered]@{
    status='failed'
    stage=$stage
    model=$model
    alias=$alias
    attempts=@()
    chosen_gpu_layers=$null
    benchmark=$null
    alias_verified=$false
    error=''
    started_utc=[DateTime]::UtcNow.ToString('o')
}
function Write-Stage([string]$name) {
    $script:stage=$name
    Write-Host ("LLM_TEST_STAGE=$name")
}
function Short-Error([string]$value) {
    if ($value.Length -gt 1000) { return $value.Substring(0,1000) }
    return $value
}
function Save-Report([string]$status,[string]$message) {
    $report.status=$status
    $report.stage=$script:stage
    $report.error=$message
    $report.completed_utc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    if (Test-Path $logs) {
        $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $logs 'placement-test-result.json') -Encoding UTF8
    }
    Write-Host ('LLM_TEST_RESULT_JSON='+($report | ConvertTo-Json -Depth 15 -Compress))
}
try {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Ollama binary on D drive: $exe" }
    if (-not (Test-Path -LiteralPath $models -PathType Container)) { throw "Missing Ollama model directory on D drive: $models" }
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS',$models,'Process')
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Process')
    [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD','1','Process')
    Write-Stage 'api'
    $ver=Invoke-RestMethod -Uri ($api+'/api/version') -Method Get -TimeoutSec 12
    $report.server_version=[string]$ver.version
    $tags=Invoke-RestMethod -Uri ($api+'/api/tags') -Method Get -TimeoutSec 15
    $matching=@($tags.models | Where-Object { [string]$_.name -eq $model })
    if ($matching.Count -ne 1) { throw "Model $model not listed; download will NOT be repeated." }
    $report.model_bytes=[long]$matching[0].size
    Write-Stage 'benchmark'
    $tries=New-Object System.Collections.ArrayList
    $succeeded=$false
    foreach ($layers in @(16,12,8,0)) {
        Write-Host ("LLM_TEST_ATTEMPT_BEGIN num_gpu=$layers")
        $request=@{
            model=$model
            prompt='Explain in two short sentences what a CPU and GPU do.'
            stream=$false
            think=$false
            keep_alive='5m'
            options=@{
                num_ctx=4096
                num_gpu=$layers
                num_batch=64
                num_predict=80
                temperature=0
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $started=[DateTime]::UtcNow
        $item=[ordered]@{num_gpu=$layers;status='failed';seconds=0;error=''}
        try {
            $result=Invoke-RestMethod -Uri ($api+'/api/generate') -Method Post -ContentType 'application/json' -Body $request -TimeoutSec 180
            $item.seconds=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,2)
            if ($null -eq $result -or $result.done -ne $true -or [string]::IsNullOrWhiteSpace([string]$result.response)) {
                throw 'Model did not return completed nonempty text.'
            }
            $item.status='success'
            $item.generated_tokens=[int]$result.eval_count
            $item.generation_tps=if ([double]$result.eval_duration -gt 0) {
                [math]::Round(([double]$result.eval_count*1e9/[double]$result.eval_duration),2)
            } else { 0 }
            $item.load_duration_s=[math]::Round(([double]$result.load_duration/1e9),2)
            $item.response=([string]$result.response).Trim()
            [void]$tries.Add($item)
            $report.chosen_gpu_layers=$layers
            $report.benchmark=$item
            $succeeded=$true
            Write-Host ("LLM_TEST_ATTEMPT_SUCCESS num_gpu=$layers tps=$($item.generation_tps) tokens=$($item.generated_tokens)")
            break
        }
        catch {
            $item.seconds=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,2)
            $item.error=Short-Error ([string]$_.Exception.Message)
            [void]$tries.Add($item)
            Write-Host ("LLM_TEST_ATTEMPT_FAILED num_gpu=$layers reason=$($item.error)")
        }
    }
    $report.attempts=@($tries.ToArray())
    if (-not $succeeded) { throw 'All partial GPU and CPU fallback attempts failed.' }
    Write-Stage 'create-configuration'
    # Create a named local model sharing the existing model blobs; no pulling and no large model copy.
    $modelfile=Join-Path $base 'Modelfile-rtx2070'
    $lines=@('FROM qwen3.5:9b',('PARAMETER num_gpu '+[string]$report.chosen_gpu_layers),'PARAMETER num_ctx 4096','PARAMETER num_batch 64')
    [IO.File]::WriteAllLines($modelfile,$lines,[Text.UTF8Encoding]::new($false))
    $report.modelfile=$modelfile
    $cliLines=@(& $exe create $alias -f $modelfile 2>&1)
    $cliExit=$LASTEXITCODE
    if ($cliExit -ne 0) {
        $report.alias_error=Short-Error (($cliLines | Out-String).Trim())
        Write-Host ("LLM_TEST_ALIAS_FAILED exit=$cliExit; raw profile works via API.")
    }
    else {
        $after=Invoke-RestMethod -Uri ($api+'/api/tags') -Method Get -TimeoutSec 25
        $report.alias_verified=@($after.models | Where-Object { [string]$_.name -eq $alias }).Count -gt 0
        Write-Host ("LLM_TEST_ALIAS_VERIFIED=$($report.alias_verified)")
    }
    $report.loaded_models=((& $exe ps 2>&1) | Out-String).Trim()
    $smi=Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $smi) {
        $report.gpu=@(& $smi.Source '--query-gpu=name,memory.total,memory.used,utilization.gpu' '--format=csv,noheader,nounits' 2>$null)
    }
    Write-Stage 'done'
    Save-Report 'success' ''
    exit 0
}
catch {
    $reason=Short-Error ([string]$_.Exception.Message)
    Write-Host ("LLM_TEST_FATAL stage=$stage reason=$reason")
    Save-Report 'failed' $reason
    exit 1
}
