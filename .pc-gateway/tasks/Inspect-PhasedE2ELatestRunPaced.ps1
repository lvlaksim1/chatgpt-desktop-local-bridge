[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$NetworkMinGapMs = 5000
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$ProcessName = 'ChatGptDesktopLocalBridge'
$ExpectedTag = 'private-transport-v5-95dd011'
$StateRoot = Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\private-transport-e2e-phased'
$socket = $null
$oldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')

function Write-ProjectResult {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{
        status=$Status
        error=$ErrorText
        exit_code=$ExitCode
        expected_release=$ExpectedTag
        pacing_ms=$NetworkMinGapMs
    }
    foreach($key in $Extra.Keys){$payload[$key]=$Extra[$key]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-BridgeApp {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle-ne0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 2
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{Stop-Process -Id $p.Id -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 1
}

function Stop-BridgeWebViewProcesses {
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($item in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*'+$needle+'*') })){
        try{Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 1
}

function Wait-BridgeProcess {
    param([int]$TimeoutSeconds=45)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow-lt$deadline){
        $items=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object {$_.MainWindowHandle-ne0} | Select-Object -First 1)
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
            $target=@($targets | Where-Object {
                $_.type-eq'page' -and $_.url-like'https://chatgpt.com/*' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
            } | Select-Object -First 1)
            if($target.Count-gt0){return $target[0]}
        }catch{}
        Start-Sleep -Seconds 5
    }
    return $null
}

function Send-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params=@{},
        [int]$TimeoutMs=180000
    )
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 50 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $segment=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]($Socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
        while($true){
            $memory=New-Object IO.MemoryStream
            try{
                do{
                    $buffer=New-Object byte[] 65536
                    $bufferSegment=New-Object ArraySegment[byte] -ArgumentList (,$buffer)
                    $receive=$Socket.ReceiveAsync($bufferSegment,$cts.Token).GetAwaiter().GetResult()
                    if($receive.MessageType-eq[Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP websocket closed.'}
                    $memory.Write($buffer,0,$receive.Count)
                }while(-not$receive.EndOfMessage)
                $message=[Text.Encoding]::UTF8.GetString($memory.ToArray())|ConvertFrom-Json
                if($null-ne$message.PSObject.Properties['id'] -and [int]$message.id-eq$Id){return $message}
            }finally{$memory.Dispose()}
        }
    }finally{$cts.Dispose()}
}

function Invoke-CdpEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Expression,
        [string]$Stage,
        [int]$TimeoutMs=240000
    )
    $response=Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression=$Expression
        returnByValue=$true
        awaitPromise=$true
    } -TimeoutMs $TimeoutMs
    $Id.Value++
    if($null-ne$response.PSObject.Properties['error']){throw($Stage+': CDP error')}
    if($null-eq$response.result -or $null-eq$response.result.result){throw($Stage+': missing result')}
    if($null-ne$response.result.PSObject.Properties['exceptionDetails']){throw($Stage+': JS exception')}
    $inner=$response.result.result
    if($null-eq$inner.PSObject.Properties['value']){throw($Stage+': missing value')}
    return $inner.value
}

$request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$probeId=[string]$request.args.probe_id
if([string]::IsNullOrWhiteSpace($probeId) -or $probeId -notmatch '^[A-Za-z0-9_-]{8,96}$'){
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'invalid_probe_id'
}

$statePath=Join-Path $StateRoot ($probeId+'.json')
if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'phase_state_missing'
}
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
$workerId=[string]$state.worker_id
if([string]::IsNullOrWhiteSpace($workerId)){
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'worker_id_missing'
}
$workerIdJson=ConvertTo-Json -InputObject $workerId -Compress

$port=Get-Random -Minimum 9400 -Maximum 9999
$cdpId=1
$installedTag=$null

try{
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'installed_app_missing'}
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    $installedTag=[string]$release.tag
    if($installedTag-ne$ExpectedTag){throw "installed_release_$installedTag"}

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port='+$port+' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe|Out-Null
    if($null-eq(Wait-BridgeProcess -TimeoutSeconds 45)){throw 'app_window_missing'}
    $target=Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if($null-eq$target){throw 'cdp_target_missing'}

    Start-Sleep -Seconds 10
    $targetItems=@($target)
    $wsUrl=if($targetItems.Count-gt0){[string]$targetItems[0].webSocketDebuggerUrl}else{''}
    if([string]::IsNullOrWhiteSpace($wsUrl)){throw 'cdp_websocket_url_missing'}

    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$wsUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    Start-Sleep -Seconds 5

    $script=@'
(async()=>{
  const NETWORK_MIN_GAP_MS=5000;
  const delay=ms=>new Promise(r=>setTimeout(r,ms));
  let netTail=Promise.resolve();
  let lastFinished=0;

  function pacedFetch(input,init={}){
    const execute=async()=>{
      const wait=Math.max(0,(lastFinished+NETWORK_MIN_GAP_MS)-Date.now());
      if(wait>0)await delay(wait);
      try{return await fetch(input,init);}
      finally{lastFinished=Date.now();}
    };
    const current=netTail.then(execute,execute);
    netTail=current.then(()=>undefined,()=>undefined);
    return current;
  }

  async function authContext(){
    const response=await pacedFetch('/api/auth/session',{
      method:'GET',credentials:'include',cache:'no-store',redirect:'error',
      headers:{accept:'application/json'}
    });
    if(!response.ok)throw new Error('auth_session_http_'+response.status);
    const session=await response.json();
    const token=typeof session?.accessToken==='string'?session.accessToken:'';
    const accountId=typeof session?.account?.id==='string'?session.account.id:'';
    if(!token)throw new Error('auth_session_missing_access_token');
    return {token,accountId};
  }

  const auth=await authContext();
  const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+auth.token};
  if(auth.accountId)headers['chatgpt-account-id']=auth.accountId;

  async function apiGet(path){
    const response=await pacedFetch(path,{
      method:'GET',credentials:'include',cache:'no-store',redirect:'error',
      headers:{...headers}
    });
    const raw=await response.text();
    let json=null;try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:response.ok,status:response.status,json};
  }

  function text(value,max=4000){
    if(value==null)return null;
    const s=String(value);
    return s.length>max?s.slice(0,max):s;
  }

  function shapeContent(value){
    if(value==null)return {type:'null'};
    if(typeof value==='string')return {type:'string',text:text(value,3000)};
    if(Array.isArray(value)){
      return {
        type:'array',
        length:value.length,
        items:value.slice(0,8).map(item=>{
          if(item==null)return {type:'null'};
          if(typeof item==='string')return {type:'string',text:text(item,1200)};
          if(typeof item==='object'){
            const out={type:'object',keys:Object.keys(item).sort().slice(0,24)};
            if(typeof item.text==='string')out.text=text(item.text,1200);
            if(typeof item.type==='string')out.item_type=item.type;
            if(typeof item.name==='string')out.name=text(item.name,300);
            return out;
          }
          return {type:typeof item,value:text(item,300)};
        })
      };
    }
    if(typeof value==='object')return {type:'object',keys:Object.keys(value).sort().slice(0,30)};
    return {type:typeof value,value:text(value,500)};
  }

  function safeMetadata(meta){
    if(!meta||typeof meta!=='object')return {keys:[],selected:{}};
    const selected={};
    for(const [k,v] of Object.entries(meta)){
      if(!/status|error|finish|reason|type|model|tool|file|capability|warning/i.test(k))continue;
      if(v==null||['string','number','boolean'].includes(typeof v))selected[k]=text(v,700);
    }
    return {keys:Object.keys(meta).sort().slice(0,40),selected};
  }

  const workerId=__WORKER_ID_JSON__;
  const task=await apiGet('/backend-api/automation/'+encodeURIComponent(workerId));
  if(!task.ok||!task.json)throw new Error('worker_detail_http_'+task.status);

  const latest=await apiGet(
    '/backend-api/automation/'+encodeURIComponent(workerId)+'/latest_backing_run?include_snapshot=true'
  );

  const j=latest.json;
  return {
    pass:true,
    task:{
      is_enabled:task.json.is_enabled===true,
      last_run_time:task.json.last_run_time??null,
      timing_mode:task.json.timing_mode??null
    },
    latest:{
      http:latest.status,
      ok:latest.ok,
      body_present:j!=null,
      top_level_keys:j&&typeof j==='object'?Object.keys(j).sort().slice(0,40):[],
      role:j?.role??null,
      kind:j?.kind??null,
      channel:j?.channel??null,
      recipient:j?.recipient??null,
      author_name:j?.author_name??null,
      is_model_input:j?.is_model_input===true,
      created_at:j?.created_at??null,
      content_text:text(j?.content_text,4000),
      content_shape:shapeContent(j?.content),
      metadata:safeMetadata(j?.metadata)
    }
  };
})()
'@
    $script=$script.Replace('__WORKER_ID_JSON__',$workerIdJson)
    if($script.Contains('__WORKER_ID_JSON__')){throw 'js_worker_binding_unresolved'}

    $value=Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'phased-latest-run-paced'
    $json=$value|ConvertTo-Json -Depth 30 -Compress
    if($json.Length-gt12000){throw 'latest_run_evidence_too_large'}

    Write-ProjectResult -Status 'evidence' -ExitCode 20 -ErrorText $json -Extra @{
        installed_tag=$installedTag
        probe_id=$probeId
        worker_id_present=$true
    }
}
catch{
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag=$installedTag
        probe_id=$probeId
    }
}
finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    try{Stop-BridgeApp}catch{}
    try{Stop-BridgeWebViewProcesses}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}
