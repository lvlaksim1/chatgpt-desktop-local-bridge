param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='failed';error='';cmd_launcher_count=0;legacy_start_count=0;launch_script_exists=$false;launch_script_syntax='';shortcut_wscript=$false;original_exe_exists=$false;process_root_count=0;launcher_log_tail=''}
try{
 $root='D:\LocalAI\Goose'
 $cmd=Join-Path $root 'Goose-RU.cmd'
 $script=Join-Path $root 'Start-Goose-RU-Single.ps1'
 $r.original_exe_exists=Test-Path -LiteralPath (Join-Path $root 'desktop\v1.56.0\Goose.exe') -PathType Leaf
 $lines=@(Get-Content -LiteralPath $cmd)
 $r.cmd_launcher_count=@($lines|Where-Object{$_ -match 'Start-Goose-RU-Single\.ps1'}).Count
 $r.legacy_start_count=@($lines|Where-Object{$_ -match '^\s*start\s'}).Count
 $r.launch_script_exists=Test-Path -LiteralPath $script -PathType Leaf
 if($r.launch_script_exists){
  $tokens=$null;$errors=$null
  $null=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
  $r.launch_script_syntax=if($errors -and $errors.Count){$errors[0].Message}else{'valid'}
 }
 $vbs=Join-Path $root 'Goose-RU.vbs'
 $r.shortcut_wscript=(Test-Path -LiteralPath $vbs -PathType Leaf) -and ((Get-Content -LiteralPath $vbs -Raw) -match 'Goose-RU\.cmd')
 $r.process_root_count=@(Get-CimInstance Win32_Process -Filter "Name='Goose.exe'"|Where-Object{([string]$_.ExecutablePath) -ieq (Join-Path $root 'desktop-ru\v1.56.0\Goose.exe') -and ([string]$_.CommandLine) -notmatch '(?i)--type='}).Count
 $log=Join-Path $root 'logs\goose-ru-single-start.log'
 if(Test-Path -LiteralPath $log -PathType Leaf){$r.launcher_log_tail=(@(Get-Content -LiteralPath $log -Tail 4) -join ' | ')}
 if($r.cmd_launcher_count -eq 1 -and $r.legacy_start_count -eq 0 -and $r.launch_script_syntax -eq 'valid' -and $r.shortcut_wscript){
  $r.status='success'
  $r.error="Installed single-window launcher validated; root=$($r.process_root_count); log=$($r.launcher_log_tail)"
 }else{$r.error="Verification failed. cmd=$($r.cmd_launcher_count) legacy=$($r.legacy_start_count) script=$($r.launch_script_syntax) vbs=$($r.shortcut_wscript)"}
}catch{$r.error=[string]$_.Exception.Message}
$r.error=([string]$r.error -replace '[\r\n]+',' ')
if($r.error.Length -gt 650){$r.error=$r.error.Substring(0,650)}
$r|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
