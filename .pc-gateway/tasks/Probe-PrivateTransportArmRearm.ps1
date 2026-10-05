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
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorText = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        status = $Status
        error = $ErrorText
        exit_code = $ExitCode
        expected_release = $ExpectedTag
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-BridgeApp {
    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
        }
        catch {}
    }

    Start-Sleep -Seconds 2

    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
    }

    Start-Sleep -Seconds 1
}

function Stop-BridgeWebViewProcesses {
    $needle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach ($item in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $needle + '*') })) {
        try { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Seconds 1
}

function Wait-BridgeProcess {
    param([int]$TimeoutSeconds = 45)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $items = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)
        if ($items.Count -gt 0) { return $items[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-ForCdpTarget {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json') -UseBasicParsing -TimeoutSec 2)
            $target = @($targets | Where-Object {
                $_.type -eq 'page' -and
                $_.url -like 'https://chatgpt.com/*' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
            } | Select-Object -First 1)

            if ($target.Count -gt 0) { return $target[0] }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Send-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 60000
    )

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 40 -Compress

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)

    try {
        [void]($Socket.SendAsync(
            $segment,
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token).GetAwaiter().GetResult())

        while ($true) {
            $memory = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $bufferSegment = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
                    $receive = $Socket.ReceiveAsync(
                        $bufferSegment,
                        $cts.Token).GetAwaiter().GetResult()

                    if ($receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'CDP websocket closed.'
                    }

                    $memory.Write($buffer, 0, $receive.Count)
                } while (-not $receive.EndOfMessage)

                $text = [Text.Encoding]::UTF8.GetString($memory.ToArray())
                $message = $text | ConvertFrom-Json
                if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
                    return $message
                }
            }
            finally {
                $memory.Dispose()
            }
        }
    }
    catch {
        if ($cts.IsCancellationRequested) {
            throw "CDP timeout after $TimeoutMs ms for $Method."
        }
        throw
    }
    finally {
        $cts.Dispose()
    }
}

function Invoke-CdpEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Expression,
        [string]$Stage,
        [int]$TimeoutMs = 60000
    )

    $response = Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    } -TimeoutMs $TimeoutMs
    $Id.Value++

    if ($null -ne $response.PSObject.Properties['error']) {
        throw ($Stage + ': CDP error: ' + ($response.error | ConvertTo-Json -Depth 10 -Compress))
    }
    if ($null -eq $response.PSObject.Properties['result'] -or
        $null -eq $response.result.PSObject.Properties['result']) {
        throw ($Stage + ': missing evaluation result')
    }

    $inner = $response.result.result
    if ($null -ne $inner.PSObject.Properties['exceptionDetails']) {
        throw ($Stage + ': JS exception: ' + ($inner.exceptionDetails | ConvertTo-Json -Depth 10 -Compress))
    }
    if ($null -eq $inner.PSObject.Properties['value']) {
        throw ($Stage + ': missing by-value payload: ' + ($inner | ConvertTo-Json -Depth 10 -Compress))
    }

    return $inner.value
}

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$port = Get-Random -Minimum 9400 -Maximum 9999
$cdpId = 1

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) { throw "Installed application is missing at '$AppExe'." }
    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) { throw 'release-info.json is missing.' }
    $release = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedTag = [string]$release.tag
    if ($installedTag -ne $ExpectedTag) { throw "Installed release '$installedTag' is not the expected '$ExpectedTag'." }

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')
    Start-Process -FilePath $AppExe | Out-Null
    $app = Wait-BridgeProcess -TimeoutSeconds 45
    if ($null -eq $app) { throw 'Application main window did not appear.' }
    $target = Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if ($null -eq $target) { throw 'ChatGPT WebView2 CDP target did not appear.' }

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    [void](Send-CdpCommand -Socket $socket -Id $cdpId -Method 'Page.navigate' -Params @{ url = 'https://chatgpt.com/' })
    $cdpId++
    Start-Sleep -Seconds 3

    $script = @"
(async () => {
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  function fmtUtc(ms) {
    const d = new Date(ms);
    const p = n => String(n).padStart(2, '0');
    return d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) +
      'T' + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds());
  }
  function onceAt(ms) {
    return 'BEGIN:VEVENT\nDTSTART;TZID=UTC:' + fmtUtc(ms) + '\nEND:VEVENT';
  }

  async function authContext() {
    const response = await fetch('/api/auth/session', {
      method:'GET',credentials:'include',cache:'no-store',redirect:'error',
      headers:{accept:'application/json'}
    });
    if (!response.ok) throw new Error('auth_session_http_' + response.status);
    const session = await response.json();
    const token = typeof session?.accessToken === 'string' ? session.accessToken : '';
    const accountId = typeof session?.account?.id === 'string' ? session.account.id : '';
    if (!token) throw new Error('auth_session_missing_access_token');
    return {token,accountId};
  }
  const auth = await authContext();
  const headers = {accept:'application/json, text/plain, */*',authorization:'Bearer ' + auth.token};
  if (auth.accountId) headers['chatgpt-account-id'] = auth.accountId;

  async function api(method,path,body) {
    const h={...headers};
    const init={method,credentials:'include',redirect:'error',cache:'no-store',headers:h};
    if (body !== undefined) { h['content-type']='application/json'; init.body=JSON.stringify(body); }
    const r=await fetch(path,init), raw=await r.text();
    let json=null; try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:r.ok,status:r.status,json,raw};
  }
  async function read(id) {
    const r=await api('GET','/backend-api/automation/'+encodeURIComponent(id));
    if(!r.ok||!r.json) throw new Error('read_http_'+r.status);
    return r.json;
  }
  async function waitFor(id,predicate,label) {
    const deadline=Date.now()+15000; let last=null;
    while(Date.now()<deadline){
      last=await read(id);
      if(predicate(last)) return last;
      await delay(250);
    }
    throw new Error('readback_timeout_'+label);
  }
  function editBody(current,schedule) {
    const body={
      default_timezone:current.default_timezone,
      email_enabled:current.email_enabled,
      is_enabled:current.is_enabled,
      jawbone_id:current.id,
      notifications_enabled:current.notifications_enabled,
      prompt:current.prompt,
      emoji:current.display_emoji,
      schedule,
      timing_mode:0,
      title:current.title
    };
    if(current.model!=null) body.model=current.model;
    if(current.reasoning_effort!=null) body.reasoning_effort=current.reasoning_effort;
    return body;
  }

  const marker='bridge-arm-probe-'+crypto.randomUUID().replaceAll('-','').slice(0,12);
  const now=Date.now();
  const s1=onceAt(now+24*60*60*1000);
  const s2=onceAt(now+25*60*60*1000);
  const s3=onceAt(now+26*60*60*1000);
  const summary={
    pass:false,code:'started',marker,createStatus:0,firstReadback:false,
    armScheduleStatus:0,armScheduleReadback:false,enableStatus:0,enabledReadback:false,
    rearmStatus:0,rearmReadback:false,nextRunPresent:false,
    disableStatus:0,disabledReadback:false,removeStatus:0,removedVerified:false
  };
  let id=null;
  try{
    const created=await api('POST','/backend-api/automations/save',{
      title:marker,
      prompt:'Transport arm/rearm contract probe. Do nothing if ever invoked.',
      schedule:s1,
      timing_mode:0,
      default_timezone:'UTC',
      executor:'cloud',
      is_enabled:false,
      legacy_automation_id:null,
      notification_policy:null,
      notifications_enabled:false,
      email_enabled:false,
      target_thread_id:null
    });
    summary.createStatus=created.status;
    if(!created.ok) throw new Error('create_http_'+created.status);
    id=typeof created.json?.id==='string'?created.json.id:null;
    if(!id) throw new Error('created_id_missing');

    let current=await waitFor(id,x=>x.schedule===s1 && x.is_enabled===false,'create');
    summary.firstReadback=true;

    let u=await api('POST','/backend-api/automations/save',editBody(current,s2));
    summary.armScheduleStatus=u.status;
    if(!u.ok) throw new Error('arm_schedule_http_'+u.status);
    current=await waitFor(id,x=>x.schedule===s2 && x.is_enabled===false,'arm_schedule');
    summary.armScheduleReadback=true;

    let e=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:true});
    summary.enableStatus=e.status;
    if(!e.ok) throw new Error('enable_http_'+e.status);
    current=await waitFor(id,x=>x.is_enabled===true,'enable');
    summary.enabledReadback=true;
    summary.nextRunPresent=Array.isArray(current.next_run_times) && current.next_run_times.length>0;

    let r=await api('POST','/backend-api/automations/save',editBody(current,s3));
    summary.rearmStatus=r.status;
    if(!r.ok) throw new Error('rearm_http_'+r.status);
    current=await waitFor(id,x=>x.schedule===s3 && x.is_enabled===true,'rearm');
    summary.rearmReadback=true;
    summary.nextRunPresent=summary.nextRunPresent &&
      Array.isArray(current.next_run_times) && current.next_run_times.length>0;

    let d=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:false});
    summary.disableStatus=d.status;
    if(!d.ok) throw new Error('disable_http_'+d.status);
    await waitFor(id,x=>x.is_enabled===false,'disable');
    summary.disabledReadback=true;

    const removed=await api('POST','/backend-api/automations/remove',{automation_id:id});
    summary.removeStatus=removed.status;
    if(!removed.ok) throw new Error('remove_http_'+removed.status);
    const deadline=Date.now()+12000;
    while(Date.now()<deadline){
      const paused=await api('GET','/backend-api/automations?filter=paused');
      if(paused.ok&&Array.isArray(paused.json?.items)&&!paused.json.items.some(x=>x&&x.id===id)){
        summary.removedVerified=true;break;
      }
      await delay(250);
    }

    summary.pass=summary.firstReadback&&summary.armScheduleReadback&&summary.enabledReadback&&
      summary.rearmReadback&&summary.nextRunPresent&&summary.disabledReadback&&summary.removedVerified;
    summary.code=summary.pass?'pass':'assertion_failed';
    return summary;
  }catch(error){
    summary.code='exception';summary.error=String(error);
    if(id){
      try{await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:false})}catch{}
      try{await api('POST','/backend-api/automations/remove',{automation_id:id})}catch{}
    }
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'arm-rearm' -TimeoutMs 120000
    $safe=[ordered]@{
        pass=[bool]$result.pass; code=[string]$result.code; marker=[string]$result.marker;
        create_http=[int]$result.createStatus; arm_schedule_http=[int]$result.armScheduleStatus;
        enable_http=[int]$result.enableStatus; enabled_readback=[bool]$result.enabledReadback;
        rearm_http=[int]$result.rearmStatus; rearm_readback=[bool]$result.rearmReadback;
        next_run_present=[bool]$result.nextRunPresent; disable_http=[int]$result.disableStatus;
        disabled_readback=[bool]$result.disabledReadback; remove_http=[int]$result.removeStatus;
        removed_verified=[bool]$result.removedVerified;
        error=if($null-ne$result.PSObject.Properties['error']){[string]$result.error}else{''}
    }
    Write-Host ('ARM_REARM_RESULT='+($safe|ConvertTo-Json -Compress))
    if(-not [bool]$result.pass){throw('Arm/rearm probe failed: '+($safe|ConvertTo-Json -Compress))}
    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra $safe
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
