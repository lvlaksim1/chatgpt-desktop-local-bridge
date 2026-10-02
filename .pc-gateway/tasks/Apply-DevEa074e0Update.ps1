[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$baseTag='dev-72b6766'
$baseCommit='72b676608d8e9ebb949af451b4dda7fd8a6061c8'
$targetTag='dev-ea074e0'
$targetCommit='ea074e06bd4e959106f49f57cad1ac731597dac3'
$asset='ChatGptDesktopLocalBridge-Update-from-dev-72b6766.exe'
$sha='1b1ae3f0ec24c662047bf5570ed320d1639624f5629a21d10807f2dd814ea2dd'
$root=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$exe=Join-Path $root 'ChatGptDesktopLocalBridge.exe'
$release=Join-Path $root 'release-info.json'
$temp=Join-Path $env:TEMP ('bridge-update-'+[Guid]::NewGuid().ToString('N'))
$upd=Join-Path $temp $asset
$log=Join-Path $temp 'update.log'
$old=[Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','Process')

function Finish([string]$status,[int]$code,[string]$error='',[hashtable]$extra=@{}){
  $p=[ordered]@{status=$status;error=$error;exit_code=$code;base_tag=$baseTag;target_tag=$targetTag;target_commit=$targetCommit}
  foreach($k in $extra.Keys){$p[$k]=$extra[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $p|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 10 -Compress))
  exit $code
}
function Stop-App {
  foreach($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)){
    try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
  }
  Start-Sleep -Seconds 2
  Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
}
try{
  if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Application executable is missing.'}
  if(-not(Test-Path -LiteralPath $release -PathType Leaf)){throw 'release-info.json is missing.'}
  $before=Get-Content -LiteralPath $release -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$before.tag -eq $targetTag -and [string]$before.commit -eq $targetCommit){
    Finish 'success' 0 '' @{already_current=$true}
  }
  if([string]$before.tag -ne $baseTag -or [string]$before.commit -ne $baseCommit){
    throw "Installed base mismatch: '$($before.tag)' '$($before.commit)'."
  }
  New-Item -ItemType Directory -Force -Path $temp|Out-Null
  $url='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/'+$targetTag+'/'+$asset
  $wc=New-Object Net.WebClient
  try{$wc.DownloadFile($url,$upd)}finally{$wc.Dispose()}
  $actual=(Get-FileHash -LiteralPath $upd -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actual -ne $sha){throw "Updater hash mismatch: $actual"}
  Stop-App
  [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')
  $p=Start-Process -FilePath $upd -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$log)) -PassThru
  if(-not $p.WaitForExit(120000)){try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{};throw 'Updater timed out.'}
  $p.Refresh()
  if($p.ExitCode -ne 0){throw "Updater failed with exit code $($p.ExitCode)."}
  $after=Get-Content -LiteralPath $release -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$after.tag -ne $targetTag -or [string]$after.commit -ne $targetCommit){
    throw "Target marker mismatch: '$($after.tag)' '$($after.commit)'."
  }
  Finish 'success' 0 '' @{already_current=$false;installed_before=[string]$before.tag;installed_after=[string]$after.tag}
}catch{
  Finish 'fail' 31 $_.Exception.Message
}finally{
  [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',$old,'Process')
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}