param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$root='D:\LocalAI\Goose'
$evidence=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence\goose-desktop-russian-20261027-c543cde-v1'
$source=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\runner\_work\pc-runner-gateway\pc-runner-gateway\source-repo-40422699116\.pc-gateway\tasks\install-goose-russian-desktop.ps1'
$logs=Join-Path $root 'logs\desktop-russian-install-result.json'
$zip=Join-Path $root 'downloads\Goose-win32-x64-v1.56.0.zip'
$launcher=Join-Path $root 'Goose-RU.cmd'
$report=@{status='diagnostic';error='';source_exists=$false;parser_errors=@();evidence_exists=$false;stderr='';stdout='';zip_exists=$false;launcher_exists=$false;result_exists=$false;result_status='';result_error=''}
$report.source_exists=Test-Path -LiteralPath $source -PathType Leaf
if($report.source_exists){
 $tokens=$null;$parseErrors=$null
 $ast=[System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
 $report.parser_errors=@($parseErrors|Select-Object -First 3|ForEach-Object{([string]$_.Message)+' line '+[string]$_.Extent.StartLineNumber})
}
$report.evidence_exists=Test-Path -LiteralPath $evidence -PathType Container
if($report.evidence_exists){
 foreach($f in @('task-stderr.log','task-stdout.log')){
  $p=Join-Path $evidence $f
  if(Test-Path $p){
   $v=(Get-Content -LiteralPath $p -Tail 8|Out-String).Trim()
   if($v.Length -gt 400){$v=$v.Substring($v.Length-400)}
   if($f -eq 'task-stderr.log'){$report.stderr=$v}else{$report.stdout=$v}
  }
 }
}
$report.zip_exists=Test-Path -LiteralPath $zip -PathType Leaf
$report.launcher_exists=Test-Path -LiteralPath $launcher -PathType Leaf
$report.result_exists=Test-Path -LiteralPath $logs -PathType Leaf
if($report.result_exists){
 try{$x=Get-Content -LiteralPath $logs -Raw|ConvertFrom-Json;$report.result_status=[string]$x.status;$report.result_error=[string]$x.error}catch{}
}
$info='source='+$report.source_exists+' parse='+($report.parser_errors -join ' ')+' stderr='+$report.stderr+' zip='+$report.zip_exists+' launcher='+$report.launcher_exists+' result='+$report.result_status+' result_error='+$report.result_error
$info=$info -replace '[\r\n\t]',' '
$info=$info -replace '[^\x20-\x7E]','?'
$info=$info -replace '[\"\\]',' '
if($info.Length -gt 520){$info=$info.Substring(0,520)}
$report.error=$info
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
