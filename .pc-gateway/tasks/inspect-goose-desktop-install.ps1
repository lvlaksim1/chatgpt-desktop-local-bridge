param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$root='D:\LocalAI\Goose'
$evidence=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence\goose-desktop-russian-20261027-c543cde-v1'
$report=@{status='diagnostic';error='';evidence=$false;files=@();stderr='';stdout='';zip_exists=$false;zip_size=0;desktop_exe_count=0;desktop_exe='';launcher_exists=$false;local_result_exists=$false;local_status='';local_error=''}
$report.evidence=Test-Path -LiteralPath $evidence -PathType Container
if($report.evidence){
 $report.files=@(Get-ChildItem -LiteralPath $evidence -File -ErrorAction SilentlyContinue|ForEach-Object{$_.Name+':'+$_.Length})
 $err=Join-Path $evidence 'task-stderr.log'
 $out=Join-Path $evidence 'task-stdout.log'
 if(Test-Path $err){$report.stderr=(Get-Content -LiteralPath $err -Tail 14|Out-String).Trim()}
 if(Test-Path $out){$report.stdout=(Get-Content -LiteralPath $out -Tail 8|Out-String).Trim()}
}
$zip=Join-Path $root 'downloads\Goose-win32-x64-v1.56.0.zip'
if(Test-Path $zip){$report.zip_exists=$true;$report.zip_size=(Get-Item $zip).Length}
$dir=Join-Path $root 'desktop\v1.56.0'
if(Test-Path $dir){
 $exes=@(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'Goose.exe' -ErrorAction SilentlyContinue)
 $report.desktop_exe_count=$exes.Count
 if($exes.Count){$report.desktop_exe=$exes[0].FullName}
}
$report.launcher_exists=Test-Path (Join-Path $root 'Goose-RU.cmd')
$local=Join-Path $root 'logs\desktop-russian-install-result.json'
if(Test-Path $local){
 $report.local_result_exists=$true
 try{$v=Get-Content -LiteralPath $local -Raw|ConvertFrom-Json;$report.local_status=$v.status;$report.local_error=$v.error}catch{}
}
$report.error="evidence=$($report.evidence) files=$($report.files -join ',') stderr=$($report.stderr) zip=$($report.zip_exists) zip_bytes=$($report.zip_size) exe_count=$($report.desktop_exe_count) launcher=$($report.launcher_exists) local=$($report.local_status) local_err=$($report.local_error)"
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
