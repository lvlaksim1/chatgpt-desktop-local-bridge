[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$path='D:\LocalAI\Ollama\logs\scheduled-stderr.log'
$report=@{status='diagnostic';error='';context_lines=@();load_errors=@();log_bytes=0;api_ok=$false}
if(Test-Path -LiteralPath $path -PathType Leaf){
 $report.log_bytes=(Get-Item -LiteralPath $path).Length
 $lines=@(Get-Content -LiteralPath $path -Tail 2000)
 $report.context_lines=@($lines|Where-Object{$_ -match '(?i)(n_ctx[ =]|OLLAMA_CONTEXT_LENGTH|KV self|KV cache size|KV buffer size|n_seq_max|ctx-size|context_size|model context)' }|Select-Object -Last 9)
 $report.load_errors=@($lines|Where-Object{$_ -match '(?i)(level=ERROR|failed to allocate|out of memory|Load failed|status 503|error 503|cannot allocate|memory available|llama-server terminated)' }|Select-Object -Last 9)
}
try{$v=Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 3;$report.api_ok=$true}catch{}
$txt='ctx='+($report.context_lines -join ' || ')+'; errors='+($report.load_errors -join ' || ')
if($txt.Length -gt 690){$txt=$txt.Substring($txt.Length-690)}
$report.error=$txt
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
