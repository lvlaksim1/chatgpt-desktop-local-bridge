param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$toolsDir=Join-Path $root 'patch-tools'
$reseditDir=Join-Path $toolsDir 'resedit-tool'
$src=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\repair-goose-ru-integrity.cjs'
$exe=Join-Path $root 'desktop-ru\v1.56.0\Goose.exe'
$originalExe=Join-Path $root 'desktop\v1.56.0\Goose.exe'
$cmd=Join-Path $root 'Goose-RU.cmd'
$vbs=Join-Path $root 'Goose-RU.vbs'
$workspace=Join-Path $root 'workspace'
$logs=Join-Path $root 'logs'
$r=[ordered]@{status='failed';stage='preflight';error='';integrity_fixed=$false;console_hidden=$false;shortcut_updated=$false;original_unchanged=$false;node_result='';launcher=$vbs;target=$exe;runtime_smoke_test='not_run'}
try {
 New-Item -ItemType Directory -Path $reseditDir,$logs,$workspace -Force|Out-Null
 foreach($p in @($src,$exe,$originalExe,$cmd)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing required file: $p"}}
 $originalHash=(Get-FileHash -LiteralPath $originalExe -Algorithm SHA256).Hash
 $node=Get-Command node.exe -ErrorAction Stop
 $r.stage='dependency'
 $module=Join-Path $reseditDir 'node_modules\resedit'
 if(-not(Test-Path -LiteralPath $module -PathType Container)){
  $npm=Get-Command npm.cmd -ErrorAction Stop
  $out=Join-Path $logs 'goose-integrity-npm.out.log'
  $err=Join-Path $logs 'goose-integrity-npm.err.log'
  $np=Start-Process -FilePath $npm.Source -ArgumentList @('install','--prefix',$reseditDir,'--no-audit','--no-fund','--no-save','--ignore-scripts','resedit@2.0.3') -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
  if(-not $np.WaitForExit(90000)){try{$np.Kill()}catch{};throw 'Timed out installing resedit'}
  $np.Refresh()
  if($np.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $module -PathType Container)){throw ('resedit installation failed: '+(Get-Content -LiteralPath $err -Tail 7|Out-String))}
 }
 $r.stage='integrity'
 $out=Join-Path $logs 'goose-integrity-repair.out.json'
 $err=Join-Path $logs 'goose-integrity-repair.err.log'
 $np=Start-Process -FilePath $node.Source -ArgumentList @($src) -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
 if(-not $np.WaitForExit(60000)){try{$np.Kill()}catch{};throw 'Timed out updating executable integrity resource'}
 $np.Refresh()
 if($np.ExitCode -ne 0){throw ('Integrity update failed: '+(Get-Content -LiteralPath $err -Tail 8|Out-String))}
 $data=Get-Content -LiteralPath $out -Raw|ConvertFrom-Json
 if($data.status -ne 'success'){throw ('Integrity verification failed: '+(Get-Content -LiteralPath $out -Raw))}
 $r.integrity_fixed=$true
 $r.node_result=([string]$data.asar_header_sha256)
 $r.original_unchanged=((Get-FileHash -LiteralPath $originalExe -Algorithm SHA256).Hash -eq $originalHash)
 if(-not $r.original_unchanged){throw 'Original Goose executable changed unexpectedly'}
 $r.stage='launcher'
 # Keep existing environment variables and CLI parameters, only correct its executable invocation.
 $lines=@(Get-Content -LiteralPath $cmd)
 $launch=0
 for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -match '^start\s'){
   $lines[$i]='start "" /D "D:\LocalAI\Goose\workspace" "D:\LocalAI\Goose\desktop-ru\v1.56.0\Goose.exe" --dir "D:\LocalAI\Goose\workspace"'
   $launch++
  }
 }
 if($launch -ne 1){throw "Expected one start command in launcher, found $launch"}
 $cmdBackup=Join-Path $root 'backups\Goose-RU.before-hidden-launch.cmd'
 New-Item -ItemType Directory -Path (Split-Path -Parent $cmdBackup) -Force|Out-Null
 if(-not(Test-Path -LiteralPath $cmdBackup)){Copy-Item -LiteralPath $cmd -Destination $cmdBackup}
 [IO.File]::WriteAllLines($cmd,$lines,[Text.Encoding]::ASCII)
 # wscript launches the environment-setting cmd without creating any visible console window.
 $script=@'
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "D:\LocalAI\Goose\Goose-RU.cmd" & Chr(34), 0, False
'@
 [IO.File]::WriteAllText($vbs,$script,(New-Object Text.UTF8Encoding($false)))
 $r.console_hidden=(Test-Path -LiteralPath $vbs -PathType Leaf)
 $r.stage='shortcut'
 $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
 if([string]::IsNullOrWhiteSpace($desktop)){throw 'Interactive desktop directory not available'}
 $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2UgLSDQoNGD0YHRgdC60LjQuS5sbms='))
 $shortcut=Join-Path $desktop $name
 $shell=New-Object -ComObject WScript.Shell
 $link=$shell.CreateShortcut($shortcut)
 $link.TargetPath=Join-Path $env:SystemRoot 'System32\wscript.exe'
 $link.Arguments='"D:\LocalAI\Goose\Goose-RU.vbs"'
 $link.WorkingDirectory=$workspace
 $link.IconLocation=$exe+',0'
 $link.Save()
 $r.shortcut_updated=$true
 $r.stage='done'
 $r.status='success'
 $r.error='Patched ASAR header digest is now embedded in Russian Goose.exe. Desktop shortcut runs a hidden launcher. GUI restart required for visual acceptance.'
}catch{$r.error=([string]$_.Exception.Message -replace '[\r\n]+',' ')}
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
