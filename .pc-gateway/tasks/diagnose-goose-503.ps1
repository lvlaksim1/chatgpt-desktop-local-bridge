[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$ollamaLog='D:\LocalAI\Ollama\logs\scheduled-stderr.log'
$gooseLog='D:\LocalAI\Goose\logs\goose-chat-stderr.log'
$gooseOut='D:\LocalAI\Goose\logs\goose-chat-stdout.log'
$report=[ordered]@{status='diagnostic';error='';ollama_log_exists=$false;ollama_errors=@();ollama_last_lines=@();goose_stderr_tail='';goose_stdout_tail='';api_online=$false;loaded_models=''}
if(Test-Path $ollamaLog){
 $report.ollama_log_exists=$true
 $tail=@(Get-Content -LiteralPath $ollamaLog -Tail 250 -ErrorAction SilentlyContinue)
 $errors=@($tail | Where-Object{$_ -match '(?i)(level=ERROR|Load failed|out of memory|failed to allocate|not enough memory|context|llama-server terminated|cudaMalloc|503|memory required|memory available|error loading|failed to load)' } | Select-Object -Last 14)
 $report.ollama_errors=@($errors|ForEach-Object { [string]$_ })
 $report.ollama_last_lines=@($tail|Select-Object -Last 6|ForEach-Object {[string]$_})
}
if(Test-Path $gooseLog){$report.goose_stderr_tail=(Get-Content -LiteralPath $gooseLog -Tail 16|Out-String).Trim()}
if(Test-Path $gooseOut){$report.goose_stdout_tail=(Get-Content -LiteralPath $gooseOut -Tail 12|Out-String).Trim()}
try{
 $null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 4
 $report.api_online=$true
 $ps=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -Method Get -TimeoutSec 4
 $report.loaded_models=@($ps.models|ForEach-Object { [string]$_.name+':'+[string]$_.size_vram }) -join ';'
}catch{}
$summary='ollama_error='+($report.ollama_errors -join ' || ')+'; goose_err='+$report.goose_stderr_tail+'; api='+$report.api_online+'; loaded='+$report.loaded_models
if($summary.Length -gt 690){$summary=$summary.Substring($summary.Length-690)}
$report.error=$summary
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
