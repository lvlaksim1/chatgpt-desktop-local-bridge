[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$root='D:\LocalAI\Goose\stage1-isolated'
$report=[ordered]@{status='failed';error='';source_file='';request_keys='';tests=@()}
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'llm_request.0.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
if($files.Count -lt 1){$report.error='No isolated Goose request found'}
else{
 $report.source_file=$files[0].Name
 $lines=@(Get-Content -LiteralPath $files[0].FullName -Tail 5 -ErrorAction SilentlyContinue)
 $inputRequest=$null
 foreach($line in $lines){
  try{$v=ConvertFrom-Json -InputObject $line;if($null -ne $v.input){$inputRequest=$v.input;break}}catch{}
 }
 if($null -eq $inputRequest){$report.error='Request input missing'}
 else{
  $report.request_keys=@($inputRequest.PSObject.Properties.Name) -join ','
  foreach($variant in @('original','reduce_ctx_and_output')){
   $request=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $inputRequest -Depth 22)
   if($variant -eq 'reduce_ctx_and_output'){
    $request.PSObject.Properties.Remove('reasoning_effort')
    if($null -eq $request.options){$request|Add-Member -NotePropertyName options -NotePropertyValue ([pscustomobject]@{})}
    $request.options|Add-Member -NotePropertyName num_ctx -NotePropertyValue 2048 -Force
    $request.options|Add-Member -NotePropertyName num_predict -NotePropertyValue 48 -Force
   }
   $item=[ordered]@{variant=$variant;status='failed';http='';seconds=0;error='';response_bytes=0}
   $start=[DateTime]::UtcNow
   try{
    $json=ConvertTo-Json -InputObject $request -Depth 22 -Compress
    $response=Invoke-WebRequest -Uri 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $json -UseBasicParsing -TimeoutSec 55 -ErrorAction Stop
    $item.http=[string][int]$response.StatusCode
    $item.response_bytes=([string]$response.Content).Length
    if([int]$response.StatusCode -eq 200){$item.status='success'}
   }catch{
    $item.error=[string]$_.Exception.Message
    try{$item.http=[string][int]$_.Exception.Response.StatusCode}catch{}
   }
   $item.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
   $report.tests+=($item)
   if($item.status -eq 'success'){break}
  }
  $summary=@($report.tests | ForEach-Object {$_.variant+':HTTP'+$_.http+':'+$_.status+':'+$_.seconds+'s:'+([string]$_.error)})
  $report.error=($summary -join ' || ')
  if(@($report.tests|Where-Object {$_.status -eq 'success'}).Count -gt 0){$report.status='success'}
 }
}
if($report.error.Length -gt 680){$report.error=$report.error.Substring(0,680)}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
