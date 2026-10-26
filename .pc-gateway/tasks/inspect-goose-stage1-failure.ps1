[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$roots=@('D:\LocalAI\Goose\stage1-isolated','D:\LocalAI\Goose','D:\LocalAI\Ollama\logs')
$report=[ordered]@{status='diagnostic';error='';root_status=@();stderr_summary='';ollama_errors=@()}
foreach($root in $roots){
  $isPresent=Test-Path -LiteralPath $root -PathType Container
  $files=@()
  if($isPresent){
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
       Where-Object {$_.Name -match '^(llm_request|stage1|scheduled-stderr|goose-stage1|.*\.jsonl)' } |
       Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8 |
       ForEach-Object {$_.Name+':'+$_.Length+':'+$_.LastWriteTimeUtc.ToString('HH:mm:ss')})
  }
  $report.root_status+=($root+':exists='+$isPresent+':files='+($files -join ','))
}
$errfile='D:\LocalAI\Goose\logs\goose-stage1-chat-stderr.log'
if(Test-Path -LiteralPath $errfile -PathType Leaf){
 $report.stderr_summary=([string](Get-Content -LiteralPath $errfile -Tail 12 | Out-String)).Trim()
}
$server='D:\LocalAI\Ollama\logs\scheduled-stderr.log'
if(Test-Path -LiteralPath $server -PathType Leaf){
 $report.ollama_errors=@(Get-Content -LiteralPath $server -Tail 400 |
  Where-Object {$_ -match '(?i)(level=ERROR|level=WARN|cudaMalloc|out of memory|failed to allocate|503|server returned error|llama-server exited|resource exhausted|context overflow|failed to load)'} |
  Select-Object -Last 5 | ForEach-Object {if($_.Length -gt 200){$_.Substring(0,200)}else{$_}})
}
$report.error='root='+($report.root_status -join ' | ')+' stderr='+$report.stderr_summary+' ollama='+($report.ollama_errors -join ' || ')
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
