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
  const delay=ms=>new Promise(r=>setTimeout(r,ms));

  async function authContext(){
    const response=await fetch('/api/auth/session',{
      method:'GET',credentials:'include',cache:'no-store',redirect:'error',
      headers:{accept:'application/json'}
    });
    if(!response.ok) throw new Error('auth_session_http_'+response.status);
    const session=await response.json();
    const token=typeof session?.accessToken==='string'?session.accessToken:'';
    const accountId=typeof session?.account?.id==='string'?session.account.id:'';
    if(!token) throw new Error('auth_session_missing_access_token');
    return {token,accountId};
  }

  const auth=await authContext();
  const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+auth.token};
  if(auth.accountId) headers['chatgpt-account-id']=auth.accountId;

  async function api(method,path,body){
    const h={...headers};
    const init={method,credentials:'include',redirect:'error',cache:'no-store',headers:h};
    if(body!==undefined){h['content-type']='application/json';init.body=JSON.stringify(body);}
    const response=await fetch(path,init);
    const raw=await response.text();
    let json=null; try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:response.ok,status:response.status,json,raw};
  }
  async function read(id){
    const r=await api('GET','/backend-api/automation/'+encodeURIComponent(id));
    if(!r.ok||!r.json) throw new Error('read_http_'+r.status);
    return r.json;
  }
  async function waitFor(id,predicate,label){
    const deadline=Date.now()+15000; let last=null;
    while(Date.now()<deadline){
      last=await read(id);
      if(predicate(last)) return last;
      await delay(250);
    }
    throw new Error('readback_timeout_'+label);
  }
  function editBody(current,schedule){
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

  const list=await api('GET','/backend-api/automations?filter=paused');
  if(!list.ok||!Array.isArray(list.json?.items)) throw new Error('paused_list_http_'+list.status);
  const candidate=list.json.items.find(x=>
    x&&typeof x.id==='string'&&x.is_enabled===false&&
    x.timing_mode==='exact_schedule'&&typeof x.schedule==='string'&&x.schedule.length>0&&
    typeof x.conversation_id==='string'&&x.conversation_id.length>0
  );
  if(!candidate) return {pass:false,code:'no_safe_task'};

  const id=candidate.id;
  const original=await read(id);
  const originalSchedule=original.schedule;
  const originalEnabled=original.is_enabled===true;
  const s2='BEGIN:VEVENT\nDTSTART:20300101T040000Z\nRRULE:FREQ=DAILY;BYHOUR=4;BYMINUTE=0\nEND:VEVENT';
  const s3='BEGIN:VEVENT\nDTSTART:20300101T050000Z\nRRULE:FREQ=DAILY;BYHOUR=5;BYMINUTE=0\nEND:VEVENT';
  const summary={
    pass:false,code:'started',taskId:id,
    armScheduleStatus:0,armScheduleReadback:false,enableStatus:0,enabledReadback:false,
    firstNextRunPresent:false,firstDisableStatus:0,firstDisabledReadback:false,
    rearmStatus:0,rearmReadback:false,rearmEnableStatus:0,rearmEnabledReadback:false,
    secondNextRunPresent:false,finalDisableStatus:0,finalDisabledReadback:false,
    restoreStatus:0,restoreReadback:false
  };

  async function restore(){
    try{
      let cur=await read(id);
      if(cur.is_enabled===true){
        await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:false});
        cur=await waitFor(id,x=>x.is_enabled===false,'restore_disable');
      }
      const rr=await api('POST','/backend-api/automations/save',editBody(cur,originalSchedule));
      summary.restoreStatus=rr.status;
      if(rr.ok){
        cur=await waitFor(id,x=>x.schedule===originalSchedule,'restore_schedule');
        if(originalEnabled){
          const re=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:true});
          if(re.ok) cur=await waitFor(id,x=>x.is_enabled===true,'restore_enable');
        }
        summary.restoreReadback=cur.schedule===originalSchedule&&cur.is_enabled===originalEnabled;
      }
    }catch{}
  }

  try{
    let cur=original;
    const a=await api('POST','/backend-api/automations/save',editBody(cur,s2));
    summary.armScheduleStatus=a.status;
    if(!a.ok) throw new Error('arm_schedule_http_'+a.status);
    cur=await waitFor(id,x=>x.schedule===s2&&x.is_enabled===false,'arm_schedule');
    summary.armScheduleReadback=true;

    const e=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:true});
    summary.enableStatus=e.status;
    if(!e.ok) throw new Error('enable_http_'+e.status);
    cur=await waitFor(id,x=>x.is_enabled===true&&x.schedule===s2,'enable');
    summary.enabledReadback=true;
    summary.firstNextRunPresent=Array.isArray(cur.next_run_times)&&cur.next_run_times.length>0;

    const d1=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:false});
    summary.firstDisableStatus=d1.status;
    if(!d1.ok) throw new Error('first_disable_http_'+d1.status);
    cur=await waitFor(id,x=>x.is_enabled===false,'first_disable');
    summary.firstDisabledReadback=true;

    const r=await api('POST','/backend-api/automations/save',editBody(cur,s3));
    summary.rearmStatus=r.status;
    if(!r.ok) throw new Error('rearm_http_'+r.status);
    cur=await waitFor(id,x=>x.schedule===s3&&x.is_enabled===false,'rearm');
    summary.rearmReadback=true;

    const e2=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:true});
    summary.rearmEnableStatus=e2.status;
    if(!e2.ok) throw new Error('rearm_enable_http_'+e2.status);
    cur=await waitFor(id,x=>x.is_enabled===true&&x.schedule===s3,'rearm_enable');
    summary.rearmEnabledReadback=true;
    summary.secondNextRunPresent=Array.isArray(cur.next_run_times)&&cur.next_run_times.length>0;

    const d2=await api('POST','/backend-api/automations/set_status',{jawbone_id:id,is_enabled:false});
    summary.finalDisableStatus=d2.status;
    if(!d2.ok) throw new Error('final_disable_http_'+d2.status);
    await waitFor(id,x=>x.is_enabled===false,'final_disable');
    summary.finalDisabledReadback=true;

    await restore();

    summary.pass=
      summary.armScheduleReadback&&summary.enabledReadback&&summary.firstNextRunPresent&&
      summary.firstDisabledReadback&&summary.rearmReadback&&summary.rearmEnabledReadback&&
      summary.secondNextRunPresent&&summary.finalDisabledReadback&&summary.restoreReadback;
    summary.code=summary.pass?'pass':'assertion_failed';
    return summary;
  }catch(error){
    summary.code='exception';summary.error=String(error);
    await restore();
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'arm-rearm-existing' -TimeoutMs 120000
    $safe=[ordered]@{
        pass=[bool]$result.pass
        code=[string]$result.code
        task_id=[string]$result.taskId
        arm_schedule_http=[int]$result.armScheduleStatus
        arm_schedule_readback=[bool]$result.armScheduleReadback
        enable_http=[int]$result.enableStatus
        enabled_readback=[bool]$result.enabledReadback
        first_next_run_present=[bool]$result.firstNextRunPresent
        first_disable_http=[int]$result.firstDisableStatus
        first_disabled_readback=[bool]$result.firstDisabledReadback
        rearm_http=[int]$result.rearmStatus
        rearm_readback=[bool]$result.rearmReadback
        rearm_enable_http=[int]$result.rearmEnableStatus
        rearm_enabled_readback=[bool]$result.rearmEnabledReadback
        second_next_run_present=[bool]$result.secondNextRunPresent
        final_disable_http=[int]$result.finalDisableStatus
        final_disabled_readback=[bool]$result.finalDisabledReadback
        restore_http=[int]$result.restoreStatus
        restore_readback=[bool]$result.restoreReadback
        error=if($null-ne$result.PSObject.Properties['error']){[string]$result.error}else{''}
    }
    Write-Host ('ARM_REARM_EXISTING_RESULT='+($safe|ConvertTo-Json -Compress))
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