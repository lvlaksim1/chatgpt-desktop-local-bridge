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
$minLeadMinutes = 30
if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['min_lead_minutes']) {
    $minLeadMinutes = [Math]::Max(15, [Math]::Min(240, [int]$request.args.min_lead_minutes))
}

$installedTag = $null
$selectedTaskId = $null
$selectedTitle = $null
$port = Get-Random -Minimum 9400 -Maximum 9999
$cdpId = 1

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

    $leadMs = [long]$minLeadMinutes * 60L * 1000L
    $script = @"
(async () => {
  const minLeadMs = $leadMs;
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
  const headers = {
    accept: 'application/json, text/plain, */*',
    authorization: 'Bearer ' + auth.token
  };
  if (auth.accountId) headers['chatgpt-account-id'] = auth.accountId;

  async function api(method, path, body) {
    const options = {
      method,
      credentials: 'include',
      redirect: 'error',
      cache: 'no-store',
      headers: { ...headers }
    };
    if (body !== undefined) {
      options.headers['content-type'] = 'application/json';
      options.body = JSON.stringify(body);
    }

    const response = await fetch(path, options);
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch {}
    return {
      ok: response.ok,
      status: response.status,
      json,
      textLength: text.length
    };
  }

  async function readAutomation(id) {
    const response = await api('GET', '/backend-api/automation/' + encodeURIComponent(id));
    if (!response.ok || !response.json) {
      throw new Error('automation_read_http_' + response.status);
    }
    return response.json;
  }

  async function waitEnabled(id, desired) {
    const deadline = Date.now() + 12000;
    let last = null;
    while (Date.now() < deadline) {
      last = await readAutomation(id);
      if (last && last.is_enabled === desired) return last;
      await delay(250);
    }
    throw new Error('readback_timeout_' + desired + '_' + String(last?.is_enabled));
  }

  const list = await api('GET', '/backend-api/automations?filter=scheduled');
  if (!list.ok || !Array.isArray(list.json?.items)) {
    throw new Error('scheduled_list_http_' + list.status);
  }

  const now = Date.now();
  const candidates = list.json.items.filter(item => {
    if (!item || item.is_enabled !== true) return false;
    if (item.timing_mode === 'condition_watch') return false;
    const next = Array.isArray(item.next_run_times) && item.next_run_times.length
      ? Date.parse(item.next_run_times[0])
      : NaN;
    return Number.isFinite(next) && next - now >= minLeadMs;
  });

  if (!candidates.length) {
    return {
      pass: false,
      code: 'no_safe_task',
      minLeadMinutes: Math.round(minLeadMs / 60000),
      scheduledCount: list.json.items.length
    };
  }

  candidates.sort((a, b) => Date.parse(b.next_run_times[0]) - Date.parse(a.next_run_times[0]));
  const task = candidates[0];
  const id = String(task.id || '');
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(id)) throw new Error('invalid_task_id');

  const summary = {
    pass: false,
    code: 'started',
    taskId: id,
    title: String(task.title || '').slice(0, 120),
    timingMode: String(task.timing_mode || ''),
    nextRun: String(task.next_run_times?.[0] || ''),
    originalEnabled: true,
    pauseStatus: 0,
    pauseReadback: null,
    resumeStatus: 0,
    resumeReadback: null,
    restored: false
  };

  try {
    const pause = await api('POST', '/backend-api/automations/set_status', {
      jawbone_id: id,
      is_enabled: false
    });
    summary.pauseStatus = pause.status;
    if (pause.status !== 201) throw new Error('pause_http_' + pause.status);

    const paused = await waitEnabled(id, false);
    summary.pauseReadback = paused.is_enabled;

    const resume = await api('POST', '/backend-api/automations/set_status', {
      jawbone_id: id,
      is_enabled: true
    });
    summary.resumeStatus = resume.status;
    if (resume.status !== 201) throw new Error('resume_http_' + resume.status);

    const resumed = await waitEnabled(id, true);
    summary.resumeReadback = resumed.is_enabled;
    summary.restored = resumed.is_enabled === true;
    summary.pass =
      summary.pauseStatus === 201 &&
      summary.pauseReadback === false &&
      summary.resumeStatus === 201 &&
      summary.resumeReadback === true &&
      summary.restored;
    summary.code = summary.pass ? 'pass' : 'assertion_failed';
    return summary;
  } catch (error) {
    try {
      await api('POST', '/backend-api/automations/set_status', {
        jawbone_id: id,
        is_enabled: true
      });
      const restored = await waitEnabled(id, true);
      summary.restored = restored.is_enabled === true;
    } catch {}

    summary.code = 'exception';
    summary.error = String(error);
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'toggle-cycle' -TimeoutMs 90000

    $selectedTaskId = [string]$result.taskId
    $selectedTitle = [string]$result.title

    if ([string]$result.code -eq 'no_safe_task') {
        Write-ProjectResult -Status 'no_safe_task' -ExitCode 20 -ErrorText (
            "No enabled non-condition task has at least $minLeadMinutes minutes before its next run.") -Extra @{
            installed_tag = $installedTag
            scheduled_count = [int]$result.scheduledCount
            min_lead_minutes = $minLeadMinutes
        }
    }

    if (-not [bool]$result.pass) {
        throw ('Control-plane toggle cycle failed: ' + ($result | ConvertTo-Json -Depth 20 -Compress))
    }

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        installed_tag = $installedTag
        task_id = $selectedTaskId
        task_title = $selectedTitle
        timing_mode = [string]$result.timingMode
        next_run = [string]$result.nextRun
        pause_http = [int]$result.pauseStatus
        pause_readback = [bool]$result.pauseReadback
        resume_http = [int]$result.resumeStatus
        resume_readback = [bool]$result.resumeReadback
        restored = [bool]$result.restored
        min_lead_minutes = $minLeadMinutes
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
        task_id = $selectedTaskId
        task_title = $selectedTitle
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

    # Intentionally leave the application stopped here. A separate bounded
    # gateway task may restore the ordinary interactive app after this probe.
    # Keeping a GUI descendant alive would prevent the gateway wrapper's
    # Start-Process -Wait from completing reliably.
}