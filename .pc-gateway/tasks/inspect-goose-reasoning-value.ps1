param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$folder='D:\LocalAI\Goose\stage1-isolated'
$result=@{status='failed';error='';reasoning='';model='';options='';fields='';tools='';messages=0}
try {
 $f=Get-ChildItem -LiteralPath $folder -Recurse -File -Filter 'llm_request.0.jsonl' |
     Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
 if(-not $f){throw 'request log absent'}
 $entry=$null
 foreach($line in @(Get-Content -LiteralPath $f.FullName -Tail 5)){
   try{$j=ConvertFrom-Json -InputObject $line;if($null -ne $j.input){$entry=$j.input;break}}catch{}
 }
 if(-not $entry){throw 'input log record absent'}
 $result.model=[string]$entry.model
 $result.reasoning=[string]$entry.reasoning_effort
 $result.fields=@($entry.PSObject.Properties.Name) -join ','
 $result.options=if($entry.options){(@($entry.options.PSObject.Properties.Name) | ForEach-Object {$k=$_; $k+'='+[string]$entry.options.$k}) -join ','}else{''}
 $result.tools=if($null -eq $entry.tools){'0'}else{[string]@($entry.tools).Count}
 $result.messages=@($entry.messages).Count
 $result.status='success'
 $result.error='model='+$result.model+' reasoning='+$result.reasoning+' fields='+$result.fields+' options='+$result.options+' tools='+$result.tools+' messages='+$result.messages
} catch{$result.error=[string]$_.Exception.Message}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
