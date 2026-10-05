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
  const marker='bridge-e2e-'+crypto.randomUUID().replaceAll('-','').slice(0,12);
  const messageId='msg-'+crypto.randomUUID().replaceAll('-','');
  const payload='FULL-FILE-PING-'+crypto.randomUUID().replaceAll('-','').slice(0,16).toUpperCase();
  const requestName=marker+'-request.json';
  const resultName=marker+'-result.json';
  const requestText=JSON.stringify({
    protocol:'FULL-FILE-DATAPLANE-V2-DESKTOP',
    message_id:messageId,
    command:'ECHO_PAYLOAD',
    payload
  });
  const requestBytes=new TextEncoder().encode(requestText);

  async function authContext(){
    const response=await fetch('/api/auth/session',{method:'GET',credentials:'include',cache:'no-store',redirect:'error',headers:{accept:'application/json'}});
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

  async function jsonApi(method,path,body){
    const h={...headers};const init={method,credentials:'include',redirect:'error',cache:'no-store',headers:h};
    if(body!==undefined){h['content-type']='application/json';init.body=JSON.stringify(body);}
    const response=await fetch(path,init);const raw=await response.text();let json=null;try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:response.ok,status:response.status,json,raw};
  }
  async function textApi(method,path,body){
    const h={...headers};const init={method,credentials:'include',redirect:'error',cache:'no-store',headers:h};
    if(body!==undefined){h['content-type']='application/json';init.body=JSON.stringify(body);}
    const response=await fetch(path,init);const raw=await response.text();
    return {ok:response.ok,status:response.status,raw};
  }
  function parseNdjson(raw){
    const out=[];for(const line of String(raw||'').split(/\r?\n/)){if(!line.trim())continue;try{out.push(JSON.parse(line))}catch{throw new Error('invalid_ndjson')}if(out.length>256)throw new Error('ndjson_too_large')}
    return out;
  }
  async function listLibrary(){
    const r=await jsonApi('POST','/backend-api/files/library',{limit:100});
    if(!r.ok||!Array.isArray(r.json?.items))throw new Error('library_list_http_'+r.status);
    return r.json.items;
  }
  async function findLibraryByFileId(fileId,timeoutMs=20000){
    const deadline=Date.now()+timeoutMs;
    while(Date.now()<deadline){const items=await listLibrary();const x=items.find(v=>v?.file_id===fileId);if(x)return x;await delay(400)}
    return null;
  }
  async function findLibraryByName(name,timeoutMs=600000){
    const deadline=Date.now()+timeoutMs;
    while(Date.now()<deadline){const items=await listLibrary();const x=items.find(v=>v?.file_name===name&&v?.trashed_at==null);if(x)return x;await delay(3000)}
    return null;
  }
  async function downloadLibrary(libId){
    const r=await fetch('/api/library/files/'+encodeURIComponent(libId)+'/download',{method:'GET',credentials:'include',redirect:'follow',cache:'no-store'});
    return {ok:r.ok,status:r.status,text:await r.text()};
  }
  async function softDelete(item){
    if(!item?.id||!item?.file_id)return {status:0,completed:false};
    const url=new URL('/backend-api/files/library/files/'+encodeURIComponent(item.id)+'/delete_stream',location.origin);
    url.searchParams.set('file_id',item.file_id);
    if(item.directory_id!=null)url.searchParams.set('parent_directory_id',String(item.directory_id));
    url.searchParams.set('file_name',item.file_name||'');
    url.searchParams.set('soft_delete','true');
    const r=await textApi('POST',url.pathname+url.search);
    const events=parseNdjson(r.raw);
    return {status:r.status,completed:events.some(x=>x?.event==='file.deletion.completed')};
  }
  async function uploadRequest(){
    const prepared=await jsonApi('POST','/backend-api/files',{
      file_name:requestName,
      file_size:requestBytes.byteLength,
      use_case:'ace_upload',
      timezone_offset_min:new Date().getTimezoneOffset(),
      reset_rate_limits:false,
      supports_direct_azure_multipart:false,
      mime_type:'application/json',
      entry_surface:'chat_composer',
      store_in_library:true,
      library_persistence_mode:'required'
    });
    if(!prepared.ok||prepared.json?.status!=='success'||typeof prepared.json?.file_id!=='string'||typeof prepared.json?.upload_url!=='string')throw new Error('prepare_http_'+prepared.status);
    const fileId=prepared.json.file_id;
    const u=new URL(prepared.json.upload_url);
    if(u.protocol!=='https:'||!u.hostname.endsWith('.oaiusercontent.com')||!u.search)throw new Error('unsafe_upload_url');
    const aws=Array.from(u.searchParams.keys()).some(k=>k.toLowerCase()==='x-amz-algorithm');
    const uploadHeaders=aws?{'Content-Type':'application/json'}:{'Content-Type':'application/json','x-ms-blob-type':'BlockBlob','x-ms-version':'2020-04-08'};
    const up=await fetch(u.href,{method:'PUT',credentials:'omit',redirect:'error',headers:uploadHeaders,body:requestBytes});
    if(!up.ok)throw new Error('upload_http_'+up.status);
    const processed=await textApi('POST','/backend-api/files/process_upload_stream',{
      file_id:fileId,file_name:requestName,use_case:'ace_upload',index_for_retrieval:true,
      entry_surface:'chat_composer',library_persistence_mode:'required',
      metadata:{store_in_library:true,is_temporary_chat:false,is_project_thread:false}
    });
    if(!processed.ok)throw new Error('process_http_'+processed.status);
    const events=parseNdjson(processed.raw);
    if(!events.some(x=>x?.event==='file.processing.completed'&&x?.file_id===fileId&&x?.progress===100))throw new Error('processing_unconfirmed');
    const item=await findLibraryByFileId(fileId,20000);
    if(!item)throw new Error('request_not_in_library');
    const downloaded=await downloadLibrary(item.id);
    if(!downloaded.ok||downloaded.text!==requestText)throw new Error('request_readback_mismatch');
    return item;
  }

  async function readTask(id){
    const r=await jsonApi('GET','/backend-api/automation/'+encodeURIComponent(id));
    if(!r.ok||!r.json)throw new Error('task_read_http_'+r.status);return r.json;
  }
  async function waitTask(id,predicate,label,timeoutMs=20000){
    const deadline=Date.now()+timeoutMs;let last=null;
    while(Date.now()<deadline){last=await readTask(id);if(predicate(last))return last;await delay(500)}
    throw new Error('task_readback_timeout_'+label);
  }
  function saveBody(cur,{prompt=cur.prompt,schedule=cur.schedule,notifications=false,email=false}={}){
    const body={
      default_timezone:cur.default_timezone,
      email_enabled:email,
      is_enabled:cur.is_enabled,
      jawbone_id:cur.id,
      notifications_enabled:notifications,
      prompt,
      emoji:cur.display_emoji,
      schedule,
      timing_mode:0,
      title:cur.title
    };
    if(cur.model!=null)body.model=cur.model;
    if(cur.reasoning_effort!=null)body.reasoning_effort=cur.reasoning_effort;
    return body;
  }
  function scheduleAt(ms){
    const d=new Date(ms);d.setUTCSeconds(0,0);
    const p=n=>String(n).padStart(2,'0');
    const stamp=d.getUTCFullYear()+p(d.getUTCMonth()+1)+p(d.getUTCDate())+'T'+p(d.getUTCHours())+p(d.getUTCMinutes())+'00Z';
    return 'BEGIN:VEVENT\nDTSTART:'+stamp+'\nRRULE:FREQ=DAILY;BYHOUR='+d.getUTCHours()+';BYMINUTE='+d.getUTCMinutes()+'\nEND:VEVENT';
  }

  const summary={
    pass:false,code:'started',marker,message_id:messageId,
    request_created:false,request_readback:false,
    task_mutation_http:0,task_mutation_readback:false,arm_http:0,arm_readback:false,
    run_observed:false,result_found:false,result_download_http:0,result_verified:false,
    latest_run_http:0,task_restored:false,request_deleted:false,result_deleted:false
  };
  let requestItem=null,resultItem=null,taskId=null,original=null;

  async function restoreTask(){
    if(!taskId||!original)return;
    try{
      let cur=await readTask(taskId);
      if(cur.is_enabled===true){
        await jsonApi('POST','/backend-api/automations/set_status',{jawbone_id:taskId,is_enabled:false});
        cur=await waitTask(taskId,x=>x.is_enabled===false,'cleanup_disable');
      }
      const rr=await jsonApi('POST','/backend-api/automations/save',saveBody(cur,{
        prompt:original.prompt,schedule:original.schedule,
        notifications:original.notifications_enabled===true,
        email:original.email_enabled===true
      }));
      if(rr.ok){
        cur=await waitTask(taskId,x=>x.prompt===original.prompt&&x.schedule===original.schedule&&x.is_enabled===false,'cleanup_restore',30000);
        summary.task_restored=true;
      }
    }catch{}
  }

  try{
    requestItem=await uploadRequest();
    summary.request_created=true;summary.request_readback=true;

    const paused=await jsonApi('GET','/backend-api/automations?filter=paused');
    if(!paused.ok||!Array.isArray(paused.json?.items))throw new Error('paused_list_http_'+paused.status);
    const preferred=paused.json.items.filter(x=>x&&x.is_enabled===false&&x.timing_mode==='exact_schedule'&&typeof x.id==='string'&&typeof x.prompt==='string'&&typeof x.schedule==='string'&&typeof x.conversation_id==='string');
    preferred.sort((a,b)=>{
      const score=x=>/probe|transport|library|ndrm|srrm|scheduled/i.test(String(x.title||''))?1:0;
      return score(b)-score(a);
    });
    const row=preferred[0];
    if(!row)throw new Error('no_worker_task');
    taskId=row.id;original=await readTask(taskId);
    const beforeLastRun=original.last_run_time||null;

    const workerPrompt=[
      'PRIVATE TRANSPORT E2E WORKER V2.',
      'Do not use conversation messages as transport input.',
      'Use the available ChatGPT Files/Library capabilities.',
      'Find the Library file named exactly: '+requestName,
      'Read and parse its JSON. It contains protocol, message_id, command and payload.',
      'Require command ECHO_PAYLOAD.',
      'Create a JSON file named exactly: '+resultName,
      'The file content must be one JSON object with exactly these semantic fields:',
      '{"protocol":"FULL-FILE-DATAPLANE-V2-DESKTOP","message_id":"<same message_id>","payload":"<same payload>","ack":"WORKER-ACK-<same payload>"}.',
      'Save/attach the file so it is durably present in ChatGPT Library before finishing.',
      'After the file has been created, final response may be only WORKER_DONE.'
    ].join('\n');

    const armedSchedule=scheduleAt(Date.now()+3*60*1000);
    const save=await jsonApi('POST','/backend-api/automations/save',saveBody(original,{prompt:workerPrompt,schedule:armedSchedule,notifications:false,email:false}));
    summary.task_mutation_http=save.status;
    if(!save.ok)throw new Error('task_mutation_http_'+save.status);
    let cur=await waitTask(taskId,x=>x.prompt===workerPrompt&&x.schedule===armedSchedule&&x.is_enabled===false,'worker_mutation',30000);
    summary.task_mutation_readback=true;

    const arm=await jsonApi('POST','/backend-api/automations/set_status',{jawbone_id:taskId,is_enabled:true});
    summary.arm_http=arm.status;
    if(!arm.ok)throw new Error('arm_http_'+arm.status);
    cur=await waitTask(taskId,x=>x.is_enabled===true&&x.schedule===armedSchedule,'arm',30000);
    summary.arm_readback=true;

    const deadline=Date.now()+12*60*1000;
    while(Date.now()<deadline){
      const nowTask=await readTask(taskId);
      if(nowTask.last_run_time&&nowTask.last_run_time!==beforeLastRun)summary.run_observed=true;
      const items=await listLibrary();
      const found=items.find(x=>x?.file_name===resultName&&x?.trashed_at==null);
      if(found){
        resultItem=found;summary.result_found=true;
        const dl=await downloadLibrary(found.id);summary.result_download_http=dl.status;
        if(dl.ok){
          try{
            const resultJson=JSON.parse(dl.text);
            summary.result_verified=
              resultJson?.protocol==='FULL-FILE-DATAPLANE-V2-DESKTOP'&&
              resultJson?.message_id===messageId&&
              resultJson?.payload===payload&&
              resultJson?.ack==='WORKER-ACK-'+payload;
          }catch{}
        }
        if(summary.result_verified&&summary.run_observed)break;
      }
      await delay(5000);
    }

    const latest=await jsonApi('GET','/backend-api/automation/'+encodeURIComponent(taskId)+'/latest_backing_run?include_snapshot=true');
    summary.latest_run_http=latest.status;

    await restoreTask();

    if(requestItem){const d=await softDelete(requestItem);summary.request_deleted=d.completed}
    if(resultItem){const d=await softDelete(resultItem);summary.result_deleted=d.completed}

    summary.pass=
      summary.request_created&&summary.request_readback&&summary.task_mutation_readback&&summary.arm_readback&&
      summary.run_observed&&summary.result_found&&summary.result_verified&&summary.latest_run_http===200&&
      summary.task_restored&&summary.request_deleted&&summary.result_deleted;
    summary.code=summary.pass?'pass':'assertion_failed';
    return summary;
  }catch(error){
    summary.code='exception';summary.error=String(error);
    await restoreTask();
    try{if(requestItem){const d=await softDelete(requestItem);summary.request_deleted=d.completed}}catch{}
    try{
      if(!resultItem){
        const items=await listLibrary();
        resultItem=items.find(x=>x?.file_name===resultName&&x?.trashed_at==null)||null;
      }
      if(resultItem){const d=await softDelete(resultItem);summary.result_deleted=d.completed}
    }catch{}
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'desktop-scheduled-library-e2e' -TimeoutMs 900000
    $safe = [ordered]@{
        pass = [bool]$result.pass
        code = [string]$result.code
        marker = [string]$result.marker
        message_id_present = -not [string]::IsNullOrWhiteSpace([string]$result.message_id)
        request_created = [bool]$result.request_created
        request_readback = [bool]$result.request_readback
        task_mutation_http = [int]$result.task_mutation_http
        task_mutation_readback = [bool]$result.task_mutation_readback
        arm_http = [int]$result.arm_http
        arm_readback = [bool]$result.arm_readback
        run_observed = [bool]$result.run_observed
        result_found = [bool]$result.result_found
        result_download_http = [int]$result.result_download_http
        result_verified = [bool]$result.result_verified
        latest_run_http = [int]$result.latest_run_http
        task_restored = [bool]$result.task_restored
        request_deleted = [bool]$result.request_deleted
        result_deleted = [bool]$result.result_deleted
        error = if ($null -ne $result.PSObject.Properties['error']) { [string]$result.error } else { '' }
    }
    Write-Host ('DESKTOP_SCHEDULED_LIBRARY_E2E_RESULT=' + ($safe | ConvertTo-Json -Compress))

    if (-not [bool]$result.pass) {
        throw ('Desktop Scheduled+Library E2E failed: ' + ($safe | ConvertTo-Json -Compress))
    }

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        installed_tag = $installedTag
        marker = [string]$result.marker
        prepare_http = [int]$result.prepareStatus
        upload_http = [int]$result.uploadStatus
        process_http = [int]$result.processStatus
        process_completed = [bool]$result.processCompleted
        library_located = [bool]$result.libraryLocated
        download_http = [int]$result.downloadStatus
        download_exact = [bool]$result.downloadExact
        rename_http = [int]$result.renameStatus
        rename_readback = [bool]$result.renameReadback
        delete_http = [int]$result.deleteStatus
        delete_completed = [bool]$result.deleteCompleted
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
    }
}
finally {
    if ($null -ne $socket) { try { $socket.Dispose() } catch {} }
    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}