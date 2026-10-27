param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$source=Join-Path $root 'desktop\v1.56.0'
$target=Join-Path $root 'desktop-ru\v1.56.0'
$srcScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\patch-goose-desktop-ru.cjs'
$toolDir=Join-Path $root 'patch-tools\node_modules\@electron\asar'
$launcher=Join-Path $root 'Goose-RU.cmd'
$report=[ordered]@{status='failed';error='';stage='preflight';target_exe='';backup_asar='';launcher=$launcher;menu_patched=$false;tooltip_patched=$false;workspace_fixed=$false;source_unchanged=$true;patch_stdout='';patch_stderr=''}
try{
 if(-not (Test-Path -LiteralPath (Join-Path $source 'Goose.exe') -PathType Leaf)){throw 'Original Goose.exe missing'}
 if(-not (Test-Path -LiteralPath $toolDir -PathType Container)){throw 'Official @electron/asar package missing'}
 if(-not (Test-Path -LiteralPath $srcScript -PathType Leaf)){throw 'Patch script not included in caller repository'}
 if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'Russian launcher not found'}
 if(Test-Path (Join-Path $source 'resources\app.asar.unpacked')){throw 'Original package has unpacked ASAR dependencies; aborting'}
 $node=Get-Command node.exe -ErrorAction Stop
 $report.stage='syntax'
 $syntaxErrors=Join-Path $root 'logs\goose-ru-js-check.err.log'
 $syntaxOut=Join-Path $root 'logs\goose-ru-js-check.out.log'
 $test=Start-Process -FilePath $node.Source -ArgumentList @('--check',$srcScript) -PassThru -NoNewWindow -RedirectStandardOutput $syntaxOut -RedirectStandardError $syntaxErrors
 if(-not $test.WaitForExit(10000)){try{$test.Kill()}catch{};throw 'Node patch syntax validation timed out'}
 $test.Refresh()
 if((Get-Item -LiteralPath $syntaxErrors).Length -gt 0){throw ('Invalid patch script: '+(Get-Content $syntaxErrors -Tail 8|Out-String))}
 $report.stage='copy'
 $targetParent=Split-Path -Parent $target
 New-Item -ItemType Directory -Path $targetParent -Force|Out-Null
 if(-not (Test-Path (Join-Path $target 'Goose.exe'))){
  New-Item -ItemType Directory -Path $target -Force|Out-Null
  Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
 }
 if(-not (Test-Path (Join-Path $target 'Goose.exe'))){throw 'Portable Goose desktop copy failed'}
 $report.target_exe=Join-Path $target 'Goose.exe'
 $report.stage='patch'
 $asar=Join-Path $target 'resources\app.asar'
 $backup=Join-Path $target 'resources\app.asar.original'
 if(-not (Test-Path -LiteralPath $backup -PathType Leaf)){
  $stdout=Join-Path $root 'logs\goose-ru-asar-patch.stdout.log'
  $stderr=Join-Path $root 'logs\goose-ru-asar-patch.stderr.log'
  $patch=Start-Process -FilePath $node.Source -ArgumentList @($srcScript,$target) -WorkingDirectory $root -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if(-not $patch.WaitForExit(90000)){try{$patch.Kill()}catch{};throw 'ASAR patch timed out after 90s'}
  $patch.Refresh()
  $report.patch_stdout=(Get-Content $stdout -Tail 3 -ErrorAction SilentlyContinue|Out-String).Trim()
  $report.patch_stderr=(Get-Content $stderr -Tail 6 -ErrorAction SilentlyContinue|Out-String).Trim()
  if(-not (Test-Path -LiteralPath $backup -PathType Leaf) -or $report.patch_stdout -notmatch '"status":"success"'){
   throw ('ASAR patch failed: '+$report.patch_stderr)
  }
 }
 $report.backup_asar=$backup
 $report.menu_patched=Test-Path $backup -PathType Leaf
 $report.tooltip_patched=$report.menu_patched
 $report.stage='launcher'
 $savedLauncher=Join-Path $root 'backups\Goose-RU.before-native-patch.cmd'
 New-Item -ItemType Directory -Path (Split-Path -Parent $savedLauncher) -Force|Out-Null
 if(-not (Test-Path -LiteralPath $savedLauncher)){Copy-Item -LiteralPath $launcher -Destination $savedLauncher}
 $lines=@(Get-Content -LiteralPath $launcher)
 $found=0
 for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -match '^start\s'){
   $lines[$i]='start "" /D "D:\LocalAI\Goose\workspace" "D:\LocalAI\Goose\desktop-ru\v1.56.0\Goose.exe" --dir "D:\LocalAI\Goose\workspace"'
   $found++
  }
 }
 if($found -ne 1){throw ('Expected one executable launch line, found '+$found)}
 [IO.File]::WriteAllLines($launcher,$lines,[Text.Encoding]::ASCII)
 $report.workspace_fixed=([string]::Join([Environment]::NewLine,$lines) -match '\-\-dir')
 $report.status='success'
 $report.stage='done'
 $report.error='Installed a separate Goose Desktop copy with Russian native menus and attachment tooltip; original unchanged; new chat directory fixed. Restart GUI to apply.'
}catch{$report.error=[string]$_.Exception.Message}
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
