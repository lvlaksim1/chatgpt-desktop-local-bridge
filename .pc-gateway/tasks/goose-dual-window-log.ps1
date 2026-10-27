param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='diagnostic';error='';log_path='';log_lines=0;matches=@();cmd='';vbs='';shortcuts=@()}
try{
 $paths=@(
  (Join-Path $env:APPDATA 'goose\logs\main.log'),
  (Join-Path $env:APPDATA 'Goose\logs\main.log'),
  (Join-Path $env:APPDATA 'goose-desktop\logs\main.log'),
  (Join-Path $env:LOCALAPPDATA 'goose\logs\main.log')
 )
 foreach($p in $paths){if(Test-Path -LiteralPath $p -PathType Leaf){$r.log_path=$p;break}}
 if($r.log_path){
  $all=@(Get-Content -LiteralPath $r.log_path -Tail 350 -ErrorAction SilentlyContinue)
  $r.log_lines=$all.Count
  $hits=@($all|Where-Object{$_ -match '(?i)create.*window|created.*window|opening.*window|open.*directory|working.dir|second.instance|new.chat|startGooseServe|new session|backend|main.window'})
  $r.matches=@($hits|Select-Object -Last 10|ForEach-Object{if($_.Length -gt 160){$_.Substring(0,160)}else{$_}})
 }
 $root='D:\LocalAI\Goose'
 $cmd=Join-Path $root 'Goose-RU.cmd'
 if(Test-Path $cmd){$r.cmd=(@(Get-Content $cmd|Where-Object{$_ -match '^start\s'}) -join '')}
 $vbs=Join-Path $root 'Goose-RU.vbs'
 if(Test-Path $vbs){$r.vbs=(Get-Content $vbs -Raw).Trim()}
 try{
  $shell=New-Object -ComObject WScript.Shell
  $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  foreach($file in @(Get-ChildItem -LiteralPath $desktop -Filter '*Goose*.lnk' -ErrorAction SilentlyContinue)){
   $lnk=$shell.CreateShortcut($file.FullName)
   $r.shortcuts+=($file.Name+': '+$lnk.TargetPath+' '+$lnk.Arguments)
  }
 }catch{}
 $r.error='log='+$r.log_path+' found='+$r.log_lines+' launcher='+$r.cmd+' window_log='+($r.matches -join ' // ')
}catch{$r.status='failed';$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 650){$r.error=$r.error.Substring(0,650)}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
