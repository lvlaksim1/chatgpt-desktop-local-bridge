param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='diagnostic';error='';stage='start';ollama_version='';model_parameters='';max_output_settings=@();request_record='';files=@()}
try {
 $root='D:\LocalAI\Goose'
 $api='http://127.0.0.1:11434'
 $r.stage='ollama'
 try {
  $v=Invoke-RestMethod -Uri ($api+'/api/version') -TimeoutSec 6
  $r.ollama_version=[string]$v.version
  $b='{"model":"qwen3.5:4b-goose"}'
  $m=Invoke-RestMethod -Uri ($api+'/api/show') -Method Post -ContentType 'application/json' -Body $b -TimeoutSec 12
  $r.model_parameters=[string]$m.parameters
 }catch{$r.error='Ollama request: '+[string]$_.Exception.Message}
 $r.stage='launchers'
 foreach($name in @('Goose-RU.cmd','Goose-Agent.cmd','Goose-Chat.cmd')){
  $p=Join-Path $root $name
  if(Test-Path -LiteralPath $p){
   $matches=@(Get-Content -LiteralPath $p|Where-Object{$_ -match '(?i)GOOSE_(MAX_TOKENS|INPUT_LIMIT|CONTEXT_LIMIT|MODEL|PROVIDER)|OLLAMA_HOST|^start\s'})
   $r.max_output_settings+=($name+'='+($matches -join '; '))
  }else{$r.max_output_settings+=($name+'=not found')}
 }
 $r.stage='logs'
 foreach($p in @(
  (Join-Path $root 'logs\qwen4b-goose-before-unlimited.json'),
  (Join-Path $root 'logs\goose-ru-header-hash.out'),
  (Join-Path $root 'backups\Goose-RU.cmd.before-output-unlimit'),
  (Join-Path $root 'backups\Goose-RU.cmd.before-output-unlimit'))){
  $r.files+=((Split-Path $p -Leaf)+':'+[string](Test-Path -LiteralPath $p))
 }
 if([string]::IsNullOrEmpty($r.error)){$r.error='model='+($r.model_parameters -replace '[\r\n]+',',')+' launchers='+($r.max_output_settings -join '|')}
}catch{$r.status='failed';$r.error=[string]$_.Exception.Message}
$r.error=([string]$r.error -replace '[\r\n\t]+',' ')
if($r.error.Length -gt 670){$r.error=$r.error.Substring(0,670)}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
