[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$baseTag='dev-aea8ad2'
$baseCommit='aea8ad2971dd7e138434b60d5dfd90c63a0f4a34'
$targetTag='dev-85c714c'
$targetCommit='85c714c9b46df2c8ea5329b2d265953d9735ee3f'
$asset='ChatGptDesktopLocalBridge-Update-from-dev-aea8ad2.exe'
$sha='cff47a28c0ff9fd57bca37f2414af5d587a323d628a57e7ed02def92c5a5dfaf'
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