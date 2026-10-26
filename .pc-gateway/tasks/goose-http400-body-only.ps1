param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$report=@{status='failed';error='';http=0;server_message='';request_fields=''}
try {
 $f=Get-ChildItem -LiteralPath 'D:\LocalAI\Goose\stage1-isolated' -Recurse -Filter 'llm_request.0.jsonl' -File |
   Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
 if(-not $f){throw 'No stored request'}
 $req=$null
 foreach($line in @(Get-Content -LiteralPath $f.FullName -Tail 4)){
  $entry=ConvertFrom-Json -InputObject $line
  if($null -ne $entry.input){$req=$entry.input;break}
 }
 if(-not $req){throw 'Stored input missing'}
 $report.request_fields=@($req.PSObject.Properties.Name) -join ','
 $json=ConvertTo-Json -InputObject $req -Depth 30 -Compress
 $url='http://127.0.0.1:11434/v1/chat/completions'
 try {
  $resp=Invoke-WebRequest -UseBasicParsing -Uri $url -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 40 -ErrorAction Stop
  $report.http=[int]$resp.StatusCode
  $report.status='success'
  $report.server_message='HTTP response '+$report.http
 } catch {
  $report.http=[int]$_.Exception.Response.StatusCode
  $stream=$_.Exception.Response.GetResponseStream()
  if($stream){
   $reader=New-Object System.IO.StreamReader($stream)
   $body=$reader.ReadToEnd()
   $reader.Dispose()
   $report.server_message=([string]$body)
  } else {$report.server_message=[string]$_.Exception.Message}
 }
 if($report.server_message.Length -gt 400){$report.server_message=$report.server_message.Substring(0,400)}
 $report.error='HTTP='+$report.http+' fields='+$report.request_fields+' server='+$report.server_message
}catch{$report.error=[string]$_.Exception.Message}
if($report.error.Length -gt 650){$report.error=$report.error.Substring(0,650)}
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
