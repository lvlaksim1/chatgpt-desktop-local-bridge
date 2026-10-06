[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$ProcessName = 'ChatGptDesktopLocalBridge'
$ExpectedTag = 'private-transport-v5-95dd011'
$socket = $null
$oldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')

function Write-ProjectResult {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;expected_release=$ExpectedTag}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-BridgeApp {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{if($p.MainWindowHandle-ne0){[void]$p.CloseMainWindow()}}catch{}}
    Start-Sleep -Seconds 2
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{Stop-Process -Id $p.Id -Force -ErrorAction Stop}catch{}}
    Start-Sleep -Seconds 1
}
function Stop-BridgeWebViewProcesses {
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine-like('*'+$needle+'*')})){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
    Start-Sleep -Seconds 1
}
function Wait-BridgeProcess {
    param([int]$TimeoutSeconds=45)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow-lt$deadline){
        $items=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle-ne0}|Select-Object -First 1)
        if($items.Count-gt0){return $items[0]}
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Wait-ForCdpTarget {
    param([int]$Port,[int]$TimeoutSeconds=60)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow-lt$deadline){
        try{
            $targets=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $target=@($targets|Where-Object{$_.type-eq'page'-and$_.url-like'https://chatgpt.com/*'-and-not[string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)}|Select-Object -First 1)
            if($target.Count-gt0){return $target[0]}
        }catch{}
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Send-CdpCommand {
    param([System.Net.WebSockets.ClientWebSocket]$Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{},[int]$TimeoutMs=60000)
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 40 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]($Socket.SendAsync($seg,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
        while($true){
            $ms=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $bseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $recv=$Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
                    if($recv.MessageType-eq[System.Net.WebSockets.WebSocketMessageType]::Close){throw'CDP websocket closed.'}
                    $ms.Write($buf,0,$recv.Count)
                }while(-not$recv.EndOfMessage)
                $msg=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
                if($null-ne$msg.PSObject.Properties['id']-and[int]$msg.id-eq$Id){return $msg}
            }finally{$ms.Dispose()}
        }
    }finally{$cts.Dispose()}
}
function Invoke-CdpEval {
    param([System.Net.WebSockets.ClientWebSocket]$Socket,[ref]$Id,[string]$Expression,[string]$Stage,[int]$TimeoutMs=60000)
    $r=Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{expression=$Expression;returnByValue=$true;awaitPromise=$true} -TimeoutMs $TimeoutMs
    $Id.Value++
    if($null-ne$r.PSObject.Properties['error']){throw($Stage+': CDP error')}
    $inner=$r.result.result
    if($null-ne$inner.PSObject.Properties['exceptionDetails']){throw($Stage+': JS exception')}
    return $inner.value
}

$port=Get-Random -Minimum 9400 -Maximum 9999
$cdpId=1
$installedTag=$null

try{
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw"Installed app missing"}
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    $installedTag=[string]$release.tag
    if($installedTag-ne$ExpectedTag){throw"Installed release '$installedTag' is not '$ExpectedTag'"}

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    if($null-eq(Wait-BridgeProcess 45)){throw'App main window missing'}
    $target=Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if($null-eq$target){throw'CDP target missing'}
    $socket=New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Send-Cdp $socket 1 'Page.navigate' @{url='https://chatgpt.com/' } 60000)
    Start-Sleep -Seconds 3

    $script=@"
(async () => {
  async function auth() {
    const r=await fetch('/api/auth/session',{credentials:'include',cache:'no-store',headers:{accept:'application/json'}});
    if(!r.ok) throw new Error('auth_'+r.status);
    const s=await r.json();
    if(typeof s?.accessToken!=='string') throw new Error('no_token');
    return {token:s.accessToken,accountId:typeof s?.account?.id==='string'?s.account.id:''};
  }
  const a=await auth();
  const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+a.token};
  if(a.accountId) headers['chatgpt-account-id']=a.accountId;
  async function list(filter){
    const r=await fetch('/backend-api/automations?filter='+encodeURIComponent(filter),{credentials:'include',cache:'no-store',headers});
    const j=await r.json();
    if(!r.ok||!Array.isArray(j?.items)) throw new Error(filter+'_'+r.status);
    return j.items;
  }
  const all=[...(await list('scheduled')),...(await list('paused')),...(await list('finished'))];
  const seen=new Set(), out=[];
  for(const x of all){
    if(!x||typeof x.id!=='string'||seen.has(x.id)) continue;
    seen.add(x.id);
    const schedule=String(x.schedule||'');
    const noRrule=!/\bRRULE:/i.test(schedule);
    if(!noRrule) continue;
    const shape=schedule
      .replace(/\d/g,'#')
      .replace(/[A-Fa-f0-9]{8,}/g,'<hex>')
      .slice(0,500);
    out.push({
      is_enabled:!!x.is_enabled,
      timing_mode:x.timing_mode??null,
      default_timezone:x.default_timezone??null,
      target_time_utc:x.target_time_utc?'<present>':null,
      next_run_count:Array.isArray(x.next_run_times)?x.next_run_times.length:0,
      frequency:x.schedule_components?.frequency??null,
      start_time_kind:x.schedule_components?.start_time==null?null:typeof x.schedule_components.start_time,
      schedule_shape:shape
    });
    if(out.length>=20) break;
  }
  return {count:out.length,items:out};
})()
"@
    $result=Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'oneshot-shapes' -TimeoutMs 90000
    $json=$result|ConvertTo-Json -Depth 12 -Compress
    Write-Host ('ONESHOT_SHAPES='+$json)
    $count=0
    if($null-ne$result -and $null-ne$result.PSObject.Properties['count']){$count=[int]$result.count}
    Write-ProjectResult -Status 'evidence' -ExitCode 20 -ErrorText $json -Extra @{installed_tag=$installedTag;count=$count}
}
catch{
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{installed_tag=$installedTag}
}
finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    try{Stop-BridgeApp}catch{}
    try{Stop-BridgeWebViewProcesses}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}