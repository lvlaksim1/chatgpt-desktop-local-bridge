param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$r=[ordered]@{status='diagnostic';error='';node='';npm='';asar_exists=$false;asar_size=0;resources_dir='';launcher_exists=$false;launcher_flags='';goose_exe_exists=$false}
try {
 $root='D:\LocalAI\Goose'
 $resources=Join-Path $root 'desktop\v1.56.0\resources'
 $r.resources_dir=$resources
 $asar=Join-Path $resources 'app.asar'
 $r.asar_exists=Test-Path $asar -PathType Leaf
 if($r.asar_exists){$r.asar_size=(Get-Item -LiteralPath $asar).Length}
 $r.goose_exe_exists=Test-Path (Join-Path $root 'desktop\v1.56.0\Goose.exe')
 $runnerNode=Get-Command node.exe -ErrorAction SilentlyContinue
 if($runnerNode){$r.node=[string]$runnerNode.Source}
 $runnerNpm=Get-Command npm.cmd -ErrorAction SilentlyContinue
 if($runnerNpm){$r.npm=[string]$runnerNpm.Source}
 $launcher=Join-Path $root 'Goose-RU.cmd'
 $r.launcher_exists=Test-Path $launcher -PathType Leaf
 if($r.launcher_exists){
  $r.launcher_flags=((Get-Content $launcher|Where-Object{$_ -match 'GOOSE_LOCALE|start |cd /d|--dir'}) -join ';')
 }
 $r.error='asar='+$r.asar_exists+' bytes='+$r.asar_size+' node='+$r.node+' npm='+$r.npm+' flags='+$r.launcher_flags
}catch{$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 600){$r.error=$r.error.Substring(0,600)}
$r|ConvertTo-Json -Depth 6|Set-Content $GatewayResultPath -Encoding UTF8
exit 0
