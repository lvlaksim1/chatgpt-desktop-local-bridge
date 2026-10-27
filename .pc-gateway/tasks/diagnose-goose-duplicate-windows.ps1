param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='diagnostic';error='';goose_process_count=0;gui_candidates=0;processes=@();launchers=@();shortcuts=@();scheduled=@();windows=@()}
try{
 $root='D:\LocalAI\Goose'
 $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
 $byid=@{}
 foreach($p in $all){$byid[[int]$p.ProcessId]=$p}
 foreach($p in @($all|Where-Object {$_.Name -ieq 'Goose.exe'}|Sort-Object CreationDate)){
  $parent=$byid[[int]$p.ParentProcessId]
  $mainWindow=0
  $windowTitle=''
  try{$gp=Get-Process -Id $p.ProcessId -ErrorAction Stop;$mainWindow=[long]$gp.MainWindowHandle;$windowTitle=[string]$gp.MainWindowTitle}catch{}
  $isHelper=([string]$p.CommandLine -match '(?i)--type=(renderer|utility|gpu-process|crashpad-handler)')
  $item=[ordered]@{id=[int]$p.ProcessId;ppid=[int]$p.ParentProcessId;parent=if($parent){[string]$parent.Name}else{'none'};session=[int]$p.SessionId;helper=$isHelper;window=($mainWindow -ne 0);window_title=$windowTitle;exe=[string]$p.ExecutablePath;cmd=[string]$p.CommandLine;created=[string]$p.CreationDate}
  $r.processes+=New-Object psobject -Property $item
 }
 $r.goose_process_count=$r.processes.Count
 $r.gui_candidates=@($r.processes|Where-Object{-not $_.helper}).Count
 foreach($name in @('Goose-RU.cmd','Goose-RU.vbs','Goose-Agent.cmd','Goose-Chat.cmd')){
  $p=Join-Path $root $name
  if(Test-Path -LiteralPath $p){$r.launchers+=([ordered]@{name=$name;path=$p;lines=@(Get-Content -LiteralPath $p|Where-Object{$_ -match '(?i)^start |shell.Run|GOOSE_MODEL|GOOSE_MAX_TOKENS|Goose.exe|--dir'})})}
 }
 $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
 $startup=[Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
 try{
  $shell=New-Object -ComObject WScript.Shell
  foreach($dir in @($desktop,$startup)){
   if(-not(Test-Path $dir)){continue}
   foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)goose'})){
    $link=$shell.CreateShortcut($file.FullName)
    $r.shortcuts+=([ordered]@{file=$file.FullName;target=$link.TargetPath;args=$link.Arguments;working_dir=$link.WorkingDirectory})
   }
  }
 }catch{$r.shortcuts+=('shortcut inspection error: '+$_.Exception.Message)}
 try{
  foreach($task in @(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskName -match '(?i)goose' -or @($_.Actions|Where-Object{$_.Execute -match '(?i)goose' -or $_.Arguments -match '(?i)goose'}).Count -gt 0})){
   $r.scheduled+=([ordered]@{name=$task.TaskName;state=[string]$task.State;actions=(@($task.Actions|ForEach-Object{[string]$_.Execute+' '+[string]$_.Arguments}) -join '|')})
  }
 }catch{}
 $roots=@($r.processes|Where-Object{-not $_.helper})
 $rootBrief=($roots|ForEach-Object{$_.id+':'+($_.exe -replace '^D:\\LocalAI\\Goose\\','')+'('+[string]$_.window+')' }) -join '; '
 $r.error='goose_processes='+$r.goose_process_count+' GUI_candidates='+$r.gui_candidates+' ROOTS='+$rootBrief+' shortcuts='+$r.shortcuts.Count+' scheduled='+$r.scheduled.Count
 if($r.error.Length -gt 670){$r.error=$r.error.Substring(0,670)}
}catch{$r.status='failed';$r.error=([string]$_.Exception.Message -replace '[\r\n]+',' ')}
$r|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
