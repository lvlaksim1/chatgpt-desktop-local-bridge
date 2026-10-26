[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$base='http://127.0.0.1:11434'
$report=[ordered]@{status='failed';error='';api_ok=$false;tests=@();utc=[DateTime]::UtcNow.ToString('o')}
try{$null=Invoke-RestMethod -Uri ($base+'/api/version') -Method Get -TimeoutSec 5;$report.api_ok=$true}catch{$report.error='Local Ollama not reachable';$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8;exit 0}
$reqs=@(
 [ordered]@{
  label='chat_no_tools'
  body=@{
   model='qwen3.5:4b'
   messages=@(@{role='user';content='Reply with exactly the digit 4.'})
   stream=$false
   max_tokens=32
   temperature=0
  }
 },
 [ordered]@{
  label='chat_with_tool'
  body=@{
   model='qwen3.5:4b'
   messages=@(@{role='user';content='Call the function record_value with value 4. Do not explain.'})
   tools=@(@{type='function';function=@{name='record_value';description='Record a number';parameters=@{type='object';properties=@{value=@{type='integer'}};required=@('value')}}})
   tool_choice='auto'
   stream=$false
   max_tokens=64
   temperature=0
  }
 }
)
foreach($req in $reqs){
 $t=[ordered]@{label=$req.label;status='failed';error='';seconds=0;content='';tool_calls=0}
 $start=[DateTime]::UtcNow
 try{
  $payload=ConvertTo-Json -InputObject $req.body -Depth 12 -Compress
  $response=Invoke-RestMethod -Uri ($base+'/v1/chat/completions') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 85
  $message=$response.choices[0].message
  $t.content=[string]$message.content
  $t.tool_calls=@($message.tool_calls).Count
  $t.status='success'
  if($t.content.Length -gt 90){$t.content=$t.content.Substring(0,90)}
 }catch{
  $t.error=[string]$_.Exception.Message
  try{
   if($null -ne $_.Exception.Response){
    $r=New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
    $txt=$r.ReadToEnd();$r.Dispose()
    if($txt){$t.error+=' server='+$txt}
   }
  }catch{}
 }
 $t.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
 $report.tests+=($t)
 if($t.status -ne 'success'){break}
}
if($report.tests.Count -eq 2 -and $report.tests[0].status -eq 'success' -and $report.tests[1].status -eq 'success'){$report.status='success'}else{$report.status='failed'}
$parts=@($report.tests|ForEach-Object{$_.label+':'+$_.status+':'+$_.seconds+'s:tools='+$_.tool_calls+':'+$_.error+':'+$_.content})
$report.error=$parts -join '; '
if($report.error.Length -gt 670){$report.error=$report.error.Substring(0,670)}
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
