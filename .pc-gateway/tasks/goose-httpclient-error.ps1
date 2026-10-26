param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$report=@{status='failed';error='';http=0;server_body=''}
try {
 Add-Type -AssemblyName System.Net.Http
 $f=Get-ChildItem 'D:\LocalAI\Goose\stage1-isolated' -Recurse -Filter 'llm_request.0.jsonl' -File | Select-Object -First 1
 if(-not $f){throw 'No stored request'}
 $req=$null
 foreach($line in @(Get-Content $f.FullName -Tail 4)){
  $v=ConvertFrom-Json $line
  if($null -ne $v.input){$req=$v.input;break}
 }
 if(-not $req){throw 'No stored input'}
 $data=ConvertTo-Json -InputObject $req -Depth 30 -Compress
 $client=New-Object System.Net.Http.HttpClient
 $client.Timeout=[TimeSpan]::FromSeconds(40)
 $payload=New-Object System.Net.Http.StringContent($data,[Text.Encoding]::UTF8,'application/json')
 $resp=$client.PostAsync('http://127.0.0.1:11434/v1/chat/completions',$payload).GetAwaiter().GetResult()
 $report.http=[int]$resp.StatusCode
 $report.server_body=$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
 if($report.server_body.Length -gt 350){$report.server_body=$report.server_body.Substring(0,350)}
 $report.status='success'
 $report.error='HTTP='+$report.http+' BODY='+$report.server_body
 $client.Dispose()
}catch{$report.error=[string]$_.Exception.Message}
if($report.error.Length -gt 650){$report.error=$report.error.Substring(0,650)}
$report|ConvertTo-Json -Depth 4|Set-Content $GatewayResultPath -Encoding UTF8
exit 0
