[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$Gap=5
$Root=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$Exe=Join-Path $Root 'ChatGptDesktopLocalBridge.exe'
$Old=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
function Stop-All{Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue;$needle='ChatGptDesktopLocalBridge\WebView2';foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}};Start-Sleep -Seconds 1}
function Finish([string]$s,[int]$c,[string]$e){@{status=$s;exit_code=$c;error=$e;network_min_gap_seconds=$Gap}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8;exit $c}
try{
 if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw 'installed_app_missing'}
 Stop-All
 $port=Get-Random -Minimum 9400 -Maximum 9999
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
 Start-Process -FilePath $Exe|Out-Null
 Start-Sleep -Seconds 15
 $items=$null
 for($i=0;$i -lt 4 -and $null -eq $items;$i++){
   try{$items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/json') -UseBasicParsing -TimeoutSec 2)}catch{if($i -lt 3){Start-Sleep -Seconds $Gap}}
 }
 if($null -eq $items){throw 'cdp_targets_unavailable'}
 $pages=@()
 foreach($t in @($items|Where-Object{$_.type -eq 'page'})){$pages += [ordered]@{title=[string]$t.title;url=[string]$t.url;has_ws=(-not [string]::IsNullOrWhiteSpace([string]$t.webSocketDebuggerUrl))}}
 Finish 'evidence' 7 (($pages|ConvertTo-Json -Depth 6 -Compress))
}catch{Finish 'fail' 40 $_.Exception.Message}
finally{try{Stop-All}catch{};[Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$Old,'Process')}
