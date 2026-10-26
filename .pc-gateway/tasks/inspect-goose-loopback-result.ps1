param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$folder='D:\LocalAI\Goose\logs'
$r=[ordered]@{status='diagnostic';error='';stdout='';stderr='';stdout_size=0;stderr_size=0;has_ready=$false}
foreach($name in @('stdout','stderr')){
 $p=Join-Path $folder ('goose-local-bypass-proxy.'+$name+'.log')
 if(Test-Path $p){
  $f=Get-Item $p
  $t=(Get-Content -LiteralPath $p -Tail 40|Out-String).Trim()
  if($t.Length -gt 600){$t=$t.Substring($t.Length-600)}
  if($name -eq 'stdout'){$r.stdout=$t;$r.stdout_size=$f.Length;$r.has_ready=($t -match 'GOOSEREADY')}
  else{$r.stderr=$t;$r.stderr_size=$f.Length}
 }
}
$r.error="ready=$($r.has_ready) stdout=$($r.stdout) stderr=$($r.stderr)"
if($r.error.Length -gt 690){$r.error=$r.error.Substring(0,690)}
$r|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
