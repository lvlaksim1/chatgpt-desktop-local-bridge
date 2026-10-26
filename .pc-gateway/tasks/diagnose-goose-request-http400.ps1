[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$report=[ordered]@{status='diagnostic';error='';request_model='';reasoning_effort='';stream='';message_shapes=@();option_keys='';variants=@()}
$root='D:\LocalAI\Goose\stage1-isolated'
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'llm_request.0.jsonl' -ErrorAction SilentlyContinue)
if($files.Count -gt 0){
 $req=$null
 foreach($line in @(Get-Content -LiteralPath $files[0].FullName -Tail 5)){
  try{$o=ConvertFrom-Json -InputObject $line;if($null -ne $o.input){$req=$o.input;break}}catch{}
 }
 if($null -ne $req){
  $report.request_model=[string]$req.model
  $report.reasoning_effort=[string]$req.reasoning_effort
  $report.stream=[string]$req.stream
  $report.option_keys=@($req.options.PSObject.Properties.Name) -join ','
  $report.message_shapes=@($req.messages|ForEach-Object {'role='+[string]$_.role+';contentType='+([string]$_.content.GetType().Name)+';contentLength='+([string]$_.content).Length})
  foreach($variant in @('original','no_reasoning','minimal_fields')){
   $clone=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $req -Depth 22)
   if($variant -ne 'original'){$clone.PSObject.Properties.Remove('reasoning_effort')}
   if($variant -eq 'minimal_fields'){
    $clone.PSObject.Properties.Remove('options')
    $clone.PSObject.Properties.Remove('stream_options')
   }
   $result=[ordered]@{variant=$variant;http=0;body='';error='';seconds=0}
   $t=[DateTime]::UtcNow
   try{
    $json=ConvertTo-Json -InputObject $clone -Depth 22 -Compress
    $client=New-Object System.Net.Http.HttpClient
    $client.Timeout=[TimeSpan]::FromSeconds(40)
    $content=New-Object System.Net.Http.StringContent($json,[Text.Encoding]::UTF8,'application/json')
    $res=$client.PostAsync('http://127.0.0.1:11434/v1/chat/completions',$content).GetAwaiter().GetResult()
    $result.http=[int]$res.StatusCode
    $body=$res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $result.body=[string]$body
    if($result.body.Length -gt 250){$result.body=$result.body.Substring(0,250)}
    $client.Dispose()
   }catch{$result.error=[string]$_.Exception.Message}
   $result.seconds=[math]::Round(([DateTime]::UtcNow-$t).TotalSeconds,1)
   $report.variants+=($result)
   if($result.http -eq 200){break}
  }
 }
}
$report.error='reasoning='+$report.reasoning_effort+' options='+$report.option_keys+' messages='+($report.message_shapes -join '|')+' results='+(@($report.variants|ForEach-Object {$_.variant+':HTTP'+$_.http+':'+$_.seconds+'s:'+([string]$_.body)+' '+$_.error}) -join ' | ')
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
