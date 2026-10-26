[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence\llm-after-reboot-generation-20261026-ae98975-v1'
$log='D:\LocalAI\Ollama\logs\reboot-probe-result.json'
$report=[ordered]@{status='diagnostic';error='';evidence_root_exists=$false;files=@();project_status='';project_error='';stdout_tail='';stderr_tail='';local_report_exists=$false;api_reachable=$false;ollama_processes=0}
function Tail([string]$file,[int]$max){
 $s=([string](Get-Content -LiteralPath $file -Tail 20 -ErrorAction Stop|Out-String)).Trim()
 if($s.Length -gt $max){return $s.Substring($s.Length-$max)}
 return $s
}
try{
 $report.evidence_root_exists=Test-Path -LiteralPath $root -PathType Container
 if($report.evidence_root_exists){
  $report.files=@(Get-ChildItem -LiteralPath $root -File|ForEach-Object { $_.Name+':'+$_.Length })
  foreach($nm in @('project-result.json','result.json','task-result.json')){
   $p=Join-Path $root $nm
   if(Test-Path -LiteralPath $p -PathType Leaf){
    try{
     $x=Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
     if($nm -eq 'project-result.json'){$report.project_status=[string]$x.status;$report.project_error=[string]$x.error}
     if($nm -eq 'result.json'){
      if($null -ne $x.summary.project_result){
       $report.result_project_status=[string]$x.summary.project_result.status
      } else { $report.result_project_status='null' }
      $report.gateway_status=[string]$x.status
      $report.gateway_exit_code=[string]$x.exit_code
     }
     if($nm -eq 'task-result.json'){$report.task_exit=[string]$x.exit_code}
    }catch{$report.project_error=([string]$_.Exception.Message)}
   }
  }
  foreach($nm in @('task-stdout.log','task-stderr.log')){
   $p=Join-Path $root $nm
   if(Test-Path $p -PathType Leaf){
    $tail=Tail $p 500
    if($nm -eq 'task-stdout.log'){$report.stdout_tail=$tail}else{$report.stderr_tail=$tail}
   }
  }
 }
 $report.local_report_exists=Test-Path -LiteralPath $log -PathType Leaf
 if($report.local_report_exists){
  try{
   $x=Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
   $report.local_status=[string]$x.status
   $report.local_error=[string]$x.error
   $report.local_attempts=@($x.attempts | ForEach-Object {"$($_.num_gpu):$($_.status):$($_.error)"})
  }catch{$report.local_error=[string]$_.Exception.Message}
 }
 $report.ollama_processes=@(Get-Process -Name 'ollama','llama-server' -ErrorAction SilentlyContinue).Count
 try{
  $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 3
  $report.api_reachable=$true
 }catch{}
 $info="Evidence=$($report.evidence_root_exists) files=$($report.files -join ',') local=$($report.local_report_exists); local_status=$($report.local_status); attempts=$($report.local_attempts -join '|'); gateway_status=$($report.gateway_status); task_exit=$($report.task_exit); report_status=$($report.project_status); stderr=$($report.stderr_tail); stdout=$($report.stdout_tail); process_count=$($report.ollama_processes); API=$($report.api_reachable)"
 if($info.Length -gt 680){$info=$info.Substring(0,680)}
 $report.error=$info
}catch{$report.status='failed';$report.error=[string]$_.Exception.Message}
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
