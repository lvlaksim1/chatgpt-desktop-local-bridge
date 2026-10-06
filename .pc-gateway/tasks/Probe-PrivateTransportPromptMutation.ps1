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
(async()=>{
  const delay=ms=>new Promise(r=>setTimeout(r,ms));
  async function authContext(){
    const r=await fetch('/api/auth/session',{credentials:'include',cache:'no-store',headers:{accept:'application/json'}});
    if(!r.ok) throw new Error('auth_'+r.status);
    const s=await r.json(); if(typeof s?.accessToken!=='string') throw new Error('no_token');
    return {token:s.accessToken,accountId:typeof s?.account?.id==='string'?s.account.id:''};
  }
  const a=await authContext();
  const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+a.token};
  if(a.accountId) headers['chatgpt-account-id']=a.accountId;
  async function api(method,path,body){
    const h={...headers};const init={method,credentials:'include',cache:'no-store',redirect:'error',headers:h};
    if(body!==undefined){h['content-type']='application/json';init.body=JSON.stringify(body);}
    const r=await fetch(path,init),raw=await r.text();let json=null;try{json=raw?JSON.parse(raw):null}catch{}
    return {ok:r.ok,status:r.status,json,raw};
  }
  async function read(id){const r=await api('GET','/backend-api/automation/'+encodeURIComponent(id));if(!r.ok||!r.json)throw new Error('read_'+r.status);return r.json;}
  async function waitFor(id,p,label){const d=Date.now()+15000;let x=null;while(Date.now()<d){x=await read(id);if(p(x))return x;await delay(250);}throw new Error('timeout_'+label);}
  function editBody(cur,prompt){
    const body={
      default_timezone:cur.default_timezone,
      email_enabled:cur.email_enabled,
      is_enabled:cur.is_enabled,
      jawbone_id:cur.id,
      notifications_enabled:cur.notifications_enabled,
      prompt,
      emoji:cur.display_emoji,
      schedule:cur.schedule,
      timing_mode:0,
      title:cur.title
    };
    if(cur.model!=null)body.model=cur.model;
    if(cur.reasoning_effort!=null)body.reasoning_effort=cur.reasoning_effort;
    return body;
  }
  const p=await api('GET','/backend-api/automations?filter=paused');
  if(!p.ok||!Array.isArray(p.json?.items))throw new Error('paused_'+p.status);
  const row=p.json.items.find(x=>x&&x.is_enabled===false&&x.timing_mode==='exact_schedule'&&typeof x.id==='string'&&typeof x.prompt==='string'&&typeof x.schedule==='string'&&typeof x.conversation_id==='string');
  if(!row)return {pass:false,code:'no_safe_task'};
  const id=row.id,original=await read(id),originalPrompt=original.prompt;
  const probePrompt='PRIVATE_TRANSPORT_PROMPT_PROBE_'+crypto.randomUUID();
  const summary={pass:false,code:'started',updateStatus:0,updateReadback:false,restoreStatus:0,restoreReadback:false};
  try{
    let u=await api('POST','/backend-api/automations/save',editBody(original,probePrompt));
    summary.updateStatus=u.status;if(!u.ok)throw new Error('update_'+u.status);
    let cur=await waitFor(id,x=>x.prompt===probePrompt&&x.is_enabled===false,'update');
    summary.updateReadback=true;
    let rr=await api('POST','/backend-api/automations/save',editBody(cur,originalPrompt));
    summary.restoreStatus=rr.status;if(!rr.ok)throw new Error('restore_'+rr.status);
    cur=await waitFor(id,x=>x.prompt===originalPrompt&&x.is_enabled===false,'restore');
    summary.restoreReadback=true;
    summary.pass=summary.updateReadback&&summary.restoreReadback;
    summary.code=summary.pass?'pass':'assertion_failed';
    return summary;
  }catch(error){
    summary.code='exception';summary.error=String(error);
    try{
      const cur=await read(id);
      if(cur.prompt!==originalPrompt){
        await api('POST','/backend-api/automations/save',editBody(cur,originalPrompt));
        await waitFor(id,x=>x.prompt===originalPrompt,'cleanup_restore');
        summary.restoreReadback=true;
      }
    }catch{}
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'prompt-mutation' -TimeoutMs 120000
    $safe=[ordered]@{
        pass=[bool]$result.pass
        code=[string]$result.code
        update_http=[int]$result.updateStatus
        update_readback=[bool]$result.updateReadback
        restore_http=[int]$result.restoreStatus
        restore_readback=[bool]$result.restoreReadback
        error=if($null-ne$result.PSObject.Properties['error']){[string]$result.error}else{''}
    }
    Write-Host ('PROMPT_MUTATION_RESULT='+($safe|ConvertTo-Json -Compress))
    if(-not [bool]$result.pass){throw('Prompt mutation probe failed: '+($safe|ConvertTo-Json -Compress))}
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