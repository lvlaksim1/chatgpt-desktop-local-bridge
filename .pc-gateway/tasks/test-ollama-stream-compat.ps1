[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$base='http://127.0.0.1:11434/v1/chat/completions'
$report=[ordered]@{status='failed';error='';results=@()}
$tests=@('stream_only','stream_with_usage','stream_with_usage_and_options')
foreach($kind in $tests){
 $data=@{
  model='qwen3.5:4b-goose'
  messages=@(@{role='user';content='Reply only with digit 4.'})
  stream=$true
  max_tokens=32
  temperature=0
 }
 if($kind -ne 'stream_only'){$data.stream_options=@{include_usage=$true}}
 if($kind -eq 'stream_with_usage_and_options'){$data.options=@{num_ctx=8192;num_predict=32}}
 $trial=[ordered]@{case=$kind;status='failed';http='';error='';seconds=0;bytes=0;first=''}
 $started=[DateTime]::UtcNow
 try{
  $json=ConvertTo-Json -InputObject $data -Compress -Depth 8
  $resp=Invoke-WebRequest -Uri $base -Method Post -UseBasicParsing -ContentType 'application/json' -Body $json -TimeoutSec 55 -ErrorAction Stop
  $trial.http=[string]$resp.StatusCode
  $trial.bytes=([string]$resp.Content).Length
  $trial.first=([string]$resp.Content)
  if($trial.first.Length -gt 110){$trial.first=$trial.first.Substring(0,110)}
  if($resp.StatusCode -eq 200){$trial.status='success'}
 }catch{
  $trial.error=[string]$_.Exception.Message
  try{
   if($null -ne $_.Exception.Response){
    $trial.http=[string][int]$_.Exception.Response.StatusCode
    $reader=New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
    $serverBody=$reader.ReadToEnd()
    $reader.Dispose()
    if($serverBody){$trial.error+='; '+$serverBody}
   }
  }catch{}
 }
 $trial.seconds=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1)
 $report.results+=($trial)
 if($trial.status -ne 'success'){break}
}
if($report.results.Count -eq $tests.Count -and @($report.results|Where-Object{$_.status -eq 'success'}).Count -eq $tests.Count){$report.status='success'}
$summary=@($report.results|ForEach-Object{$_.case+':HTTP'+$_.http+':'+$_.status+':'+$_.seconds+'s:'+([string]$_.error)})
$report.error=$summary -join ' | '
if($report.error.Length -gt 680){$report.error=$report.error.Substring(0,680)}
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
