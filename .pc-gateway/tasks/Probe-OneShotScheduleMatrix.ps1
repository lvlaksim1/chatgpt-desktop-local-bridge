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
function Stop-App {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{if($p.MainWindowHandle-ne0){[void]$p.CloseMainWindow()}}catch{}}
    Start-Sleep 2
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{Stop-Process -Id $p.Id -Force}catch{}}
    Start-Sleep 1
}
function Stop-WebView {
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine-like('*'+$needle+'*')})){try{Stop-Process -Id ([int]$p.ProcessId -Force)}catch{}}
}
function Wait-App([int]$Timeout=45){
    $d=[DateTime]::UtcNow.AddSeconds($Timeout)
    while([DateTime]::UtcNow-lt$d){
        $x=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle-ne0}|Select-Object -First 1)
        if($x.Count){return $x[0]}
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Wait-Target([int]$Port,[int]$Timeout=60){
    $d=[DateTime]::UtcNow.AddSeconds($Timeout)
    while([DateTime]::UtcNow-lt$d){
        try{
            $targets=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $x=@($targets|Where-Object{$_.type-eq'page'-and$_.url-like'https://chatgpt.com/*'-and$_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($x.Count){return $x[0]}
        }catch{}
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Send-Cdp($Socket,[int]$Id,[string]$Method,[hashtable]$Params,[int]$TimeoutMs=90000){
    $json=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 40 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]$Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while($true){
            $ms=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $bseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $r=$Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
                    if($r.MessageType-eq[Net.WebSockets.WebSocketMessageType]::Close){throw'CDP closed'}
                    $ms.Write($buf,0,$r.Count)
                }while(-not$r.EndOfMessage)
                $m=[Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json
                if($null-ne$m.PSObject.Properties['id']-and[int]$m.id-eq$Id){return $m}
            }finally{$ms.Dispose()}
        }
    }finally{$cts.Dispose()}
}

$port=Get-Random -Minimum 9400 -Maximum 9999
$installedTag=$null
try{
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    $installedTag=[string]$release.tag
    if($installedTag-ne$ExpectedTag){throw"installed_release_$installedTag"}
    Stop-App; Stop-WebView
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    if($null-eq(Wait-App 45)){throw'app_window_missing'}
    $target=Wait-Target $port 60
    if($null-eq$target){throw'cdp_target_missing'}
    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $script=@"
(async()=>{
  const delay=ms=>new Promise(r=>setTimeout(r,ms));
  const s=await (await fetch('/api/auth/session',{credentials:'include',cache:'no-store',headers:{accept:'application/json'}})).json();
  if(typeof s?.accessToken!=='string') throw new Error('no_token');
  const h={accept:'application/json, text/plain, */*',authorization:'Bearer '+s.accessToken};
  if(typeof s?.account?.id==='string') h['chatgpt-account-id']=s.account.id;
  async function api(method,path,body){
    const hh={...h}; const init={method,credentials:'include',cache:'no-store',redirect:'error',headers:hh};
    if(body!==undefined){hh['content-type']='application/json';init.body=JSON.stringify(body);}
    const r=await fetch(path,init); const raw=await r.text(); let json=null; try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:r.ok,status:r.status,json,raw};
  }
  function fmt(ms,z){
    const d=new Date(ms),p=n=>String(n).padStart(2,'0');
    const base=d.getUTCFullYear()+p(d.getUTCMonth()+1)+p(d.getUTCDate())+'T'+p(d.getUTCHours())+p(d.getUTCMinutes())+p(d.getUTCSeconds());
    return z?base+'Z':base;
  }
  const t=Date.now()+24*60*60*1000;
  const z=fmt(t,true), n=fmt(t,false);
  const marker='bridge-oneshot-matrix-'+crypto.randomUUID().replaceAll('-','').slice(0,10);
  const candidates=[
    {name:'z-int',schedule:'BEGIN:VEVENT\nDTSTART:'+z+'\nEND:VEVENT',timing_mode:0},
    {name:'floating-int',schedule:'BEGIN:VEVENT\nDTSTART:'+n+'\nEND:VEVENT',timing_mode:0},
    {name:'tzid-int',schedule:'BEGIN:VEVENT\nDTSTART;TZID=UTC:'+n+'\nEND:VEVENT',timing_mode:0},
    {name:'z-string',schedule:'BEGIN:VEVENT\nDTSTART:'+z+'\nEND:VEVENT',timing_mode:'exact_schedule'},
    {name:'floating-string',schedule:'BEGIN:VEVENT\nDTSTART:'+n+'\nEND:VEVENT',timing_mode:'exact_schedule'},
    {name:'tzid-string',schedule:'BEGIN:VEVENT\nDTSTART;TZID=UTC:'+n+'\nEND:VEVENT',timing_mode:'exact_schedule'}
  ];
  const results=[];
  for(const c of candidates){
    const title=marker+'-'+c.name;
    const body={
      title,
      prompt:'Disposable one-shot format probe. Do nothing if invoked.',
      schedule:c.schedule,
      timing_mode:c.timing_mode,
      default_timezone:'UTC',
      executor:'cloud',
      is_enabled:false,
      jawbone_id:null,
      legacy_automation_id:null,
      notification_policy:null,
      notifications_enabled:false,
      email_enabled:false,
      target_thread_id:null
    };
    const r=await api('POST','/backend-api/automations/save',body);
    const detail=typeof r.json?.detail==='string'?r.json.detail:
      r.json?.detail?JSON.stringify(r.json.detail):'';
    let id=typeof r.json?.id==='string'?r.json.id:typeof r.json?.jawbone_id==='string'?r.json.jawbone_id:null;
    if(!id && r.ok){
      await delay(250);
      const list=await api('GET','/backend-api/automations?filter=paused');
      const found=Array.isArray(list.json?.items)?list.json.items.find(x=>x?.title===title):null;
      if(typeof found?.id==='string') id=found.id;
    }
    let cleanupStatus=0;
    if(id){
      const d=await api('POST','/backend-api/automations/remove',{automation_id:id});
      cleanupStatus=d.status;
    }
    results.push({
      name:c.name,
      status:r.status,
      ok:r.ok,
      detail:String(detail).slice(0,300),
      created:!!id,
      cleanup_status:cleanupStatus
    });
  }
  const winners=results.filter(x=>x.ok&&x.created);
  return {marker,results,winner_count:winners.length,winners:winners.map(x=>x.name)};
})()
"@
    $resp=Send-Cdp $socket 1 'Runtime.evaluate' @{expression=$script;returnByValue=$true;awaitPromise=$true} 120000
    if($null-ne$resp.PSObject.Properties['error']){throw'cdp_error'}
    $value=$resp.result.result.value
    $json=$value|ConvertTo-Json -Depth 12 -Compress
    Write-Host ('ONESHOT_MATRIX='+$json)
    $winnerCount=0
    if($null-ne$value.PSObject.Properties['winner_count']){$winnerCount=[int]$value.winner_count}
    $status=if($winnerCount-gt0){'evidence'}else{'no_match'}
    Write-ProjectResult -Status $status -ExitCode 20 -ErrorText $json -Extra @{installed_tag=$installedTag;winner_count=$winnerCount}
}
catch{
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{installed_tag=$installedTag}
}
finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    try{Stop-App}catch{}; try{Stop-WebView}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}
