param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$r=[ordered]@{status='failed';stage='start';error='';processes=@();root_process_count=0;backend_count=0;launch='';vbs='';log_tail='';result_time_utc=[DateTime]::UtcNow.ToString('o')}
try{
 $r.stage='targeted-processes'
 $ps=@(Get-CimInstance Win32_Process -Filter "Name='Goose.exe'" -ErrorAction Stop)
 foreach($p in $ps){
  $cmd=[string]$p.CommandLine
  $exe=[string]$p.ExecutablePath
  $backend=$exe.ToLowerInvariant().Contains('\resources\bin\goose.exe')
  $helper=($cmd -match '(?i)--type=(renderer|utility|gpu-process|crashpad-handler)')
  $dir=''
  if($cmd -match '(?i)--dir\s+"?([^"]+?)(?:"\s|"$|\s--|\s*$)'){$dir=$matches[1].Trim()}
  $entry=[ordered]@{id=[int]$p.ProcessId;parent=[int]$p.ParentProcessId;backend=$backend;helper=$helper;dir=$dir;exe=($exe -replace '^D:\\LocalAI\\Goose\\','');started=[string]$p.CreationDate}
  $r.processes+= $entry
  if($backend){$r.backend_count++}elseif(-not $helper){$r.root_process_count++}
 }
 $r.stage='launcher'
 $cmdPath='D:\LocalAI\Goose\Goose-RU.cmd'
 if(Test-Path -LiteralPath $cmdPath -PathType Leaf){
  $r.launch=(@(Get-Content -LiteralPath $cmdPath -ErrorAction Stop|Where-Object{$_ -match '(?i)^start\s|GOOSE_PATH_ROOT|GOOSE_MODEL|GOOSE_MAX_TOKENS'}) -join ' ; ')
 }
 $vbsPath='D:\LocalAI\Goose\Goose-RU.vbs'
 if(Test-Path -LiteralPath $vbsPath -PathType Leaf){$r.vbs=(Get-Content -LiteralPath $vbsPath -Raw).Trim()}
 $r.status='diagnostic'
 $r.stage='done'
 $r.error="main=$($r.root_process_count) backend=$($r.backend_count) dirs=$(@($r.processes|Where-Object{$_.dir}|ForEach-Object{$_.dir}) -join ' + ') launch=$($r.launch)"
}catch{$r.error="$($r.stage): $([string]$_.Exception.Message)"}
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
