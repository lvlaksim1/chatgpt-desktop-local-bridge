param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$root='D:\LocalAI\Goose\logs'
$result=[ordered]@{status='diagnostic';error=''}
foreach($name in @('goose-ru-header-hash.err','goose-ru-header-hash.out')){
 $p=Join-Path $root $name
 if(Test-Path -LiteralPath $p -PathType Leaf){
  $val=(Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue)
  $val=($val -replace '[\r\n\t]+',' ')
  if($val.Length -gt 350){$val=$val.Substring(0,350)}
  $result[$name]=('bytes='+(Get-Item $p).Length+' text='+$val)
 }else{$result[$name]='not found'}
}
$result.error=([string]$result['goose-ru-header-hash.err']+' | '+[string]$result['goose-ru-header-hash.out'])
if($result.error.Length -gt 680){$result.error=$result.error.Substring(0,680)}
$result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
