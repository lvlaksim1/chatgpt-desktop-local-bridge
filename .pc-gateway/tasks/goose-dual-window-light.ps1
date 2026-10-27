param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='diagnostic';error='';process_count=0;visible_processes=0;processes=@();desktop_shortcut='';launch_line='';vbs='';ollama_api=''}
try {
 $ps=@(Get-Process -Name Goose -ErrorAction SilentlyContinue)
 $r.process_count=$ps.Count
 foreach($p in $ps){
  $exe='';$title='';$pidNumber=[int]$p.Id;$wid=[long]0
  try{$exe=[string]$p.MainModule.FileName}catch{}
  try{$title=[string]$p.MainWindowTitle;$wid=[long]$p.MainWindowHandle}catch{}
  if($wid -ne 0){$r.visible_processes++}
  $r.processes+=([ordered]@{pid=$pidNumber;exe=$exe;window=($wid -ne 0);title=$title})
  try{$p.Dispose()}catch{}
 }
 $root='D:\LocalAI\Goose'
 $cmd=Join-Path $root 'Goose-RU.cmd'
 if(Test-Path $cmd){$r.launch_line=((Get-Content -LiteralPath $cmd|Where-Object{$_ -match '^start\s'}) -join ' | ')}
 $vbs=Join-Path $root 'Goose-RU.vbs'
 if(Test-Path $vbs){$r.vbs=(Get-Content -LiteralPath $vbs -Raw).Trim()}
 try{
  $shell=New-Object -ComObject WScript.Shell
  $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2UgLSDQoNGD0YHRgdC60LjQuS5sbms='))
  $shortcut=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) $name
  if(Test-Path $shortcut){$l=$shell.CreateShortcut($shortcut);$r.desktop_shortcut=$l.TargetPath+' '+$l.Arguments}
 }catch{$r.desktop_shortcut='error: '+$_.Exception.Message}
 $r.error='Goose processes='+$r.process_count+' visible='+$r.visible_processes+' '+(@($r.processes|ForEach-Object{[string]$_.pid+' '+[string]$_.exe+' mainWindow='+[string]$_.window}) -join '; ')
}catch{$r.status='failed';$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 650){$r.error=$r.error.Substring(0,650)}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
