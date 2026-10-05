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
$createdId = $null
$probeTitle = $null

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        throw "Installed application is missing at '$AppExe'."
    }
    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) {
        throw 'release-info.json is missing.'
    }

    $release = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedTag = [string]$release.tag
    if ($installedTag -ne $ExpectedTag) {
        throw "Installed release '$installedTag' is not the expected '$ExpectedTag'."
    }

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

  async function authContext() {
    const response = await fetch('/api/auth/session', {
      method: 'GET',
      credentials: 'include',
      cache: 'no-store',
      redirect: 'error',
      headers: { accept: 'application/json' }
    });
    if (!response.ok) throw new Error('auth_session_http_' + response.status);
    const session = await response.json();
    const token = typeof session?.accessToken === 'string' ? session.accessToken : '';
    const accountId = typeof session?.account?.id === 'string' ? session.account.id : '';
    if (!token) throw new Error('auth_session_missing_access_token');
    return { token, accountId };
  }

  const auth = await authContext();
  const baseHeaders = {
    accept: 'application/json, text/plain, */*',
    authorization: 'Bearer ' + auth.token
  };
  if (auth.accountId) baseHeaders['chatgpt-account-id'] = auth.accountId;

  async function api(method, path, body) {
    const headers = { ...baseHeaders };
    const options = {
      method,
      credentials: 'include',
      redirect: 'error',
      cache: 'no-store',
      headers
    };
    if (body !== undefined) {
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    const response = await fetch(path, options);
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch {}
    return { ok: response.ok, status: response.status, json, textLength: text.length };
  }

  async function readAutomation(id) {
    const r = await api('GET', '/backend-api/automation/' + encodeURIComponent(id));
    if (!r.ok || !r.json) throw new Error('automation_read_http_' + r.status);
    return r.json;
  }

  async function waitSchedule(id, expected) {
    const deadline = Date.now() + 12000;
    let last = null;
    while (Date.now() < deadline) {
      last = await readAutomation(id);
      if (last && last.schedule === expected) return last;
      await delay(250);
    }
    throw new Error('schedule_readback_timeout');
  }

  const marker = 'bridge-schedule-probe-' + crypto.randomUUID().replaceAll('-', '').slice(0, 12);
  const scheduleA = 'BEGIN:VEVENT\nDTSTART:20300101T030000Z\nRRULE:FREQ=DAILY;BYHOUR=3;BYMINUTE=0\nEND:VEVENT';
  const scheduleB = 'BEGIN:VEVENT\nDTSTART:20300101T040000Z\nRRULE:FREQ=DAILY;BYHOUR=4;BYMINUTE=0\nEND:VEVENT';

  const common = {
    title: marker,
    prompt: 'Transport schedule contract probe. Do nothing if ever invoked.',
    timing_mode: 0,
    default_timezone: 'UTC',
    executor: 'cloud',
    is_enabled: false,
    legacy_automation_id: null,
    notification_policy: null,
    notifications_enabled: false,
    email_enabled: false,
    target_thread_id: null
  };

  const summary = {
    pass: false,
    code: 'started',
    title: marker,
    createdId: null,
    createStatus: 0,
    createScheduleReadback: false,
    updateStatus: 0,
    updateScheduleReadback: false,
    updateDetail: null,
    removeStatus: 0,
    removedVerified: false,
    updateRequestFields: null,
    updateResponseKeys: null
  };

  let id = null;

  try {
    // Clean only stale probes created by this harness.
    const stale = await api('GET', '/backend-api/automations?filter=paused');
    if (stale.ok && Array.isArray(stale.json?.items)) {
      for (const item of stale.json.items) {
        if (item && typeof item.id === 'string' &&
            typeof item.title === 'string' &&
            item.title.startsWith('bridge-schedule-probe-')) {
          await api('POST', '/backend-api/automations/remove', { automation_id: item.id });
        }
      }
    }
    const createBody = { ...common, schedule: scheduleA, jawbone_id: null };
    const created = await api('POST', '/backend-api/automations/save', createBody);
    summary.createStatus = created.status;
    if (!created.ok) throw new Error('create_http_' + created.status);

    if (created.json && typeof created.json.id === 'string') id = created.json.id;
    if (!id && created.json && typeof created.json.jawbone_id === 'string') id = created.json.jawbone_id;

    if (!id) {
      const paused = await api('GET', '/backend-api/automations?filter=paused');
      if (!paused.ok || !Array.isArray(paused.json?.items)) throw new Error('paused_list_http_' + paused.status);
      const found = paused.json.items.find(x => x && x.title === marker);
      if (found && typeof found.id === 'string') id = found.id;
    }

    if (!id) throw new Error('created_id_not_found');
    summary.createdId = id;

    const first = await waitSchedule(id, scheduleA);
    summary.createScheduleReadback = first.schedule === scheduleA;
    if (first.is_enabled !== false) throw new Error('created_probe_not_paused');

    const updateBody = { ...common, schedule: scheduleB, jawbone_id: id };
    summary.updateRequestFields = Object.keys(updateBody).sort();
    const updated = await api('POST', '/backend-api/automations/save', updateBody);
    summary.updateStatus = updated.status;
    summary.updateResponseKeys = updated.json && typeof updated.json === 'object'
      ? Object.keys(updated.json).sort()
      : [];
    if (updated.json && updated.json.detail != null) {
      summary.updateDetail = String(
        typeof updated.json.detail === 'string'
          ? updated.json.detail
          : JSON.stringify(updated.json.detail)
      ).slice(0, 600);
    }
    if (!updated.ok) throw new Error('update_http_' + updated.status);

    const second = await waitSchedule(id, scheduleB);
    summary.updateScheduleReadback = second.schedule === scheduleB;
    if (second.is_enabled !== false) throw new Error('updated_probe_became_enabled');

    const removed = await api('POST', '/backend-api/automations/remove', { automation_id: id });
    summary.removeStatus = removed.status;
    if (!removed.ok) throw new Error('remove_http_' + removed.status);

    const deadline = Date.now() + 12000;
    while (Date.now() < deadline) {
      const paused = await api('GET', '/backend-api/automations?filter=paused');
      if (paused.ok && Array.isArray(paused.json?.items)) {
        const exists = paused.json.items.some(x => x && x.id === id);
        if (!exists) {
          summary.removedVerified = true;
          break;
        }
      }
      await delay(250);
    }

    summary.pass =
      summary.createStatus >= 200 && summary.createStatus < 300 &&
      summary.createScheduleReadback === true &&
      summary.updateStatus >= 200 && summary.updateStatus < 300 &&
      summary.updateScheduleReadback === true &&
      summary.removeStatus >= 200 && summary.removeStatus < 300 &&
      summary.removedVerified === true;
    summary.code = summary.pass ? 'pass' : 'assertion_failed';
    return summary;
  } catch (error) {
    summary.code = 'exception';
    summary.error = String(error);

    if (id) {
      try {
        const removed = await api('POST', '/backend-api/automations/remove', { automation_id: id });
        summary.removeStatus = removed.status;
        const deadline = Date.now() + 6000;
        while (Date.now() < deadline) {
          const paused = await api('GET', '/backend-api/automations?filter=paused');
          if (paused.ok && Array.isArray(paused.json?.items) &&
              !paused.json.items.some(x => x && x.id === id)) {
            summary.removedVerified = true;
            break;
          }
          await delay(250);
        }
      } catch {}
    }
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'schedule-contract' -TimeoutMs 90000

    if ($null -ne $result.PSObject.Properties['createdId']) { $createdId = [string]$result.createdId }
    if ($null -ne $result.PSObject.Properties['title']) { $probeTitle = [string]$result.title }

    if (-not [bool]$result.pass) {
        throw ('Schedule contract probe failed: ' + ($result | ConvertTo-Json -Depth 20 -Compress))
    }

    Write-Host ('SCHEDULE_PROBE_RESULT=' + ([ordered]@{
        probe_title = $probeTitle
        automation_id = $createdId
        create_http = [int]$result.createStatus
        create_schedule_readback = [bool]$result.createScheduleReadback
        update_http = [int]$result.updateStatus
        update_schedule_readback = [bool]$result.updateScheduleReadback
        remove_http = [int]$result.removeStatus
        removed_verified = [bool]$result.removedVerified
        update_request_fields = @($result.updateRequestFields)
        update_response_keys = @($result.updateResponseKeys)
    } | ConvertTo-Json -Depth 8 -Compress))

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        installed_tag = $installedTag
        probe_title = $probeTitle
        automation_id = $createdId
        create_http = [int]$result.createStatus
        create_schedule_readback = [bool]$result.createScheduleReadback
        update_http = [int]$result.updateStatus
        update_schedule_readback = [bool]$result.updateScheduleReadback
        remove_http = [int]$result.removeStatus
        removed_verified = [bool]$result.removedVerified
        update_request_fields = @($result.updateRequestFields)
        update_response_keys = @($result.updateResponseKeys)
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
        probe_title = $probeTitle
        automation_id = $createdId
    }
}
finally {
    if ($null -ne $socket) {
        try { $socket.Dispose() } catch {}
    }

    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        $oldBrowserArgs,
        'Process')
}