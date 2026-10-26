[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$base='D:\LocalAI\Goose\logs'
$report=[ordered]@{status='diagnostic';error='';files=@();stdout='';stderr='';stdout_length=0;stderr_length=0;provider_config_exists=$false}
$out=Join-Path $base 'nonstream-goose.stdout.log'
$err=Join-Path $base 'nonstream-goose.stderr.log'
foreach($f in @($out,$err)){
 if(Test-Path -LiteralPath $f -PathType Leaf){
  $meta=Get-Item -LiteralPath $f
  $report.files+=($meta.Name+':'+$meta.Length)
  $txt=(Get-Content -LiteralPath $f -Tail 40 -ErrorAction SilentlyContinue|Out-String).Trim()
  if($txt.Length -gt 430){$txt=$txt.Substring($txt.Length-430)}
  if($f -eq $out){$report.stdout=$txt;$report.stdout_length=[long]$meta.Length}
  else{$report.stderr=$txt;$report.stderr_length=[long]$meta.Length}
 }
}
$cfg=Join-Path $env:APPDATA 'Block\goose\config\custom_providers\ollama_local_no_stream.json'
$report.provider_config_exists=Test-Path -LiteralPath $cfg -PathType Leaf
$report.error='files='+($report.files -join ',')+' provider_config='+$report.provider_config_exists+' stdout='+$report.stdout+' stderr='+$report.stderr
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
