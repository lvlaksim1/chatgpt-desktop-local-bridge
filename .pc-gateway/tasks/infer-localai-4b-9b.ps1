[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Ollama'
$report=[ordered]@{status='failed';error='';api_version='';results=@();completed_utc=''}
try{
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 5
 $report.api_version=[string]$v.version
 $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 5
 $installed=@($tags.models | ForEach-Object { [string]$_.name })
 if($installed -notcontains 'qwen3.5:4b'){throw 'qwen3.5:4b missing from persistent server'}
 if($installed -notcontains 'qwen3.5:9b'){throw 'qwen3.5:9b missing from persistent server'}
 $entries=New-Object System.Collections.ArrayList
 foreach($model in @('qwen3.5:4b','qwen3.5:9b')){
  $entry=[ordered]@{model=$model;status='failed';error='';seconds=0;response='';tokens=0;tokens_per_second=0;num_gpu=8;num_ctx=1024}
  $start=[DateTime]::UtcNow
  $req=@{
   model=$model
   prompt='What is 2 plus 2? Reply with one numeral only.'
   stream=$false
   think=$false
   keep_alive=0
   options=@{num_gpu=8;num_ctx=1024;num_batch=32;num_predict=48;temperature=0}
  }
  $json=ConvertTo-Json -InputObject $req -Depth 8 -Compress
  try{
   $out=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 150
   if($out.done -ne $true){throw 'Response was not complete'}
   $entry.response=([string]$out.response).Trim()
   if([string]::IsNullOrWhiteSpace($entry.response)){throw 'Response was empty'}
   $entry.tokens=[int]$out.eval_count
   if([double]$out.eval_duration -gt 0){$entry.tokens_per_second=[math]::Round([double]$out.eval_count*1000000000/[double]$out.eval_duration,2)}
   $entry.status='success'
  }catch{
   $entry.error=[string]$_.Exception.Message
   try{
    if($null -ne $_.Exception.Response){
     $rd=New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
     $txt=$rd.ReadToEnd()
     $rd.Dispose()
     if($txt){$entry.error+='; '+$txt}
    }
   }catch{}
  }
  $entry.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
  [void]$entries.Add($entry)
  if($entry.status -ne 'success' -and $model -eq 'qwen3.5:4b'){break}
 }
 $report.results=@($entries.ToArray())
 if($report.results.Count -eq 2 -and $report.results[0].status -eq 'success' -and $report.results[1].status -eq 'success'){$report.status='success'}
 elseif($report.results.Count -gt 0 -and $report.results[0].status -eq 'success'){$report.status='partial'}
 else {$report.status='failed'}
 $parts=@($report.results|ForEach-Object{"$($_.model)=$($_.status),tps=$($_.tokens_per_second),seconds=$($_.seconds),reply=$($_.response),error=$($_.error)"})
 $report.error=$parts -join ' || '
}catch{
 $report.status='failed'
 $report.error=[string]$_.Exception.Message
}
if($report.status -ne 'success'){
 $log='D:\LocalAI\Ollama\logs\scheduled-stderr.log'
 if(Test-Path -LiteralPath $log -PathType Leaf){
  $errors=@(Get-Content -LiteralPath $log -Tail 100 | Where-Object{$_ -match '(?i)(level=ERROR|failed to allocate|cudaMalloc|Load failed|llama-server terminated)'} | Select-Object -Last 2)
  $report.error+='; log='+($errors -join ' | ')
 }
}
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report.completed_utc=[DateTime]::UtcNow.ToString('o')
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $base 'logs\inference-4b-9b-result.json') -Encoding UTF8
exit 0
