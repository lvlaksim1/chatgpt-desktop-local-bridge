[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root='D:\LocalAI\Ollama'
$bin=Join-Path $root 'bin'
$exe=Join-Path $bin 'ollama.exe'
$models=Join-Path $root 'models'
$logs=Join-Path $root 'logs'
$downloads=Join-Path $root 'downloads'
$zip=Join-Path $downloads 'ollama-windows-amd64-v0.40.11.zip'
$url='https://github.com/ollama/ollama/releases/download/v0.40.11/ollama-windows-amd64.zip'
$expectedHash='bda4a493ba8a7c24d57263cd843cd68cee84f44aed4299eeed532acad7eda12a'
$model='qwen3.5:9b'
$stage='preflight'
$report=[ordered]@{status='failed';stage=$stage;error='';model=$model;binary_path=$exe;models_path=$models;started_utc=[DateTime]::UtcNow.ToString('o')}
function Stage([string]$name) {
    $script:stage=$name
    Write-Host ('LLM_STAGE='+$name)
}
function Save([string]$status,[string]$err) {
    $report.status=$status
    $report.stage=$script:stage
    $report.error=$err
    $report.completed_utc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
}
function Server-Version {
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { return [string](Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 4).version }
        catch { Start-Sleep -Seconds 2 }
    }
    throw 'Local Ollama API not ready on 127.0.0.1:11434'
}
try {
    if (-not (Test-Path 'D:\')) { throw 'D drive unavailable' }
    $drive=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'"
    if ($null -eq $drive -or [double]$drive.FreeSpace -lt 20GB) { throw 'Less than 20 GiB free on D' }
    foreach ($p in @($root,$models,$logs,$downloads)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $oldServer=$null
    try { $oldServer=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 3 } catch {}
    if ($null -ne $oldServer -and -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Existing Ollama on port 11434; refusing to interfere' }
    Stage 'download'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $needDownload=$true
        if (Test-Path -LiteralPath $zip) {
            if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedHash) { $needDownload=$false }
            else { Remove-Item $zip -Force }
        }
        if ($needDownload) {
            $tempZip=$zip+'.part'
            if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
            $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($null -ne $curl) {
                & $curl.Source '--location' '--fail' '--retry' '3' '--retry-delay' '10' '--connect-timeout' '30' '--max-time' '4200' '--silent' '--show-error' '--output' $tempZip $url
                if ($LASTEXITCODE -ne 0) { throw "Download failed; curl exit code $LASTEXITCODE" }
            } else {
                [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                $client=New-Object Net.WebClient
                try { $client.DownloadFile($url,$tempZip) } finally { $client.Dispose() }
            }
            Move-Item -LiteralPath $tempZip -Destination $zip -Force
        }
        Stage 'verify_archive'
        $hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $expectedHash) { throw "SHA256 mismatch: $hash" }
        $report.archive_sha256=$hash
        Stage 'extract'
        $staging=Join-Path $root 'bin.staging'
        if (Test-Path $staging) { Remove-Item $staging -Force -Recurse }
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        $found=@(Get-ChildItem $staging -Filter ollama.exe -File -Recurse)
        if ($found.Count -ne 1) { throw 'Executable not uniquely found in archive' }
        $payloadDir=Split-Path -Parent $found[0].FullName
        if (Test-Path $bin) {
            if (-not (Test-Path $exe)) { Remove-Item $bin -Recurse -Force }
        }
        if (-not (Test-Path $bin)) { Move-Item -LiteralPath $payloadDir -Destination $bin }
        if (-not (Test-Path $exe)) { throw 'Executable missing after extraction' }
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    }
    Stage 'configure'
    foreach ($pair in @(
        @('OLLAMA_MODELS',$models),@('OLLAMA_HOST','127.0.0.1:11434'),
        @('OLLAMA_NO_CLOUD','1'),@('OLLAMA_NUM_PARALLEL','1'),@('OLLAMA_MAX_LOADED_MODELS','1')
    )) {
        [Environment]::SetEnvironmentVariable([string]$pair[0],[string]$pair[1],'User')
        [Environment]::SetEnvironmentVariable([string]$pair[0],[string]$pair[1],'Process')
    }
    $launcher=Join-Path $root 'Start-Ollama.cmd'
    $launcherLines=@(
        '@echo off','set "OLLAMA_MODELS='+$models+'"','set "OLLAMA_HOST=127.0.0.1:11434"',
        'set "OLLAMA_NO_CLOUD=1"','set "OLLAMA_NUM_PARALLEL=1"','set "OLLAMA_MAX_LOADED_MODELS=1"',
        '"'+$exe+'" serve'
    )
    [IO.File]::WriteAllLines($launcher,$launcherLines,[Text.Encoding]::ASCII)
    $report.launcher=$launcher
    $report.binary_version=((& $exe '--version' 2>&1) | Out-String).Trim()
    Stage 'start_server'
    if ($null -eq $oldServer) {
        $tracker=[Environment]::GetEnvironmentVariable('RUNNER_TRACKING_ID','Process')
        try {
            [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID',$null,'Process')
            $proc=Start-Process -FilePath $exe -ArgumentList 'serve' -WorkingDirectory $bin -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'server.stdout.log') -RedirectStandardError (Join-Path $logs 'server.stderr.log') -PassThru
            $report.server_pid=$proc.Id
        } finally {
            [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID',$tracker,'Process')
        }
    }
    $report.server_version=Server-Version
    Stage 'pull_model'
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$exe
    $psi.Arguments='pull '+$model
    $psi.WorkingDirectory=$bin
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['OLLAMA_MODELS']=$models
    $psi.EnvironmentVariables['OLLAMA_HOST']='127.0.0.1:11434'
    $pull=New-Object Diagnostics.Process
    $pull.StartInfo=$psi
    $null=$pull.Start()
    $outTask=$pull.StandardOutput.ReadToEndAsync()
    $errTask=$pull.StandardError.ReadToEndAsync()
    if (-not $pull.WaitForExit(14400000)) {
        try { $pull.Kill() } catch {}
        throw 'Model download timed out after 4 hours'
    }
    $pull.WaitForExit()
    $pullText=$outTask.Result + [Environment]::NewLine + $errTask.Result
    [IO.File]::WriteAllText((Join-Path $logs 'model-pull.log'),$pullText)
    $report.pull_exit_code=$pull.ExitCode
    if ($pull.ExitCode -ne 0) {
        if ($pullText.Length -gt 800) { $pullText=$pullText.Substring($pullText.Length-800) }
        throw "Model download failed: $pullText"
    }
    Stage 'verify_model'
    $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 30
    $entry=@($tags.models | Where-Object { $_.name -eq $model })
    if ($entry.Count -eq 0) { throw 'Model not listed by API after download' }
    $report.model_bytes=[long]$entry[0].size
    Stage 'benchmark'
    $body=@{model=$model;prompt='Reply with exactly one English word: READY';stream=$false;think=$false;keep_alive='10m';options=@{num_ctx=4096;num_predict=96;temperature=0}} | ConvertTo-Json -Depth 10 -Compress
    $response=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 600
    $report.benchmark=[ordered]@{
        answer=([string]$response.response).Trim()
        total_seconds=[math]::Round(([double]$response.total_duration/1e9),2)
        generated_tokens=[int]$response.eval_count
        generated_tps=if ([double]$response.eval_duration -gt 0) {[math]::Round(([double]$response.eval_count*1e9/[double]$response.eval_duration),2)} else {0}
    }
    $report.model_runtime=((& $exe ps) | Out-String).Trim()
    $smi=Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($null -ne $smi) { $report.nvidia_gpu=@(& $smi.Source '--query-gpu=name,memory.total,memory.used,utilization.gpu' '--format=csv,noheader,nounits' 2>$null) }
    $report.free_d_gib=[math]::Round(([double](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'").FreeSpace/1GB),2)
    Write-Host ('LLM_SETUP_JSON='+($report | ConvertTo-Json -Depth 20 -Compress))
    Save 'success' ''
    exit 0
} catch {
    $message=$_.Exception.Message
    Write-Host ('LLM_SETUP_FAILED stage='+$stage+' error='+$message)
    try {
        $errFile=Join-Path $logs 'server.stderr.log'
        if (Test-Path $errFile) { $report.server_log_tail=(Get-Content $errFile -Tail 10 | Out-String).Trim() }
    } catch {}
    Save 'failed' $message
    exit 1
}
