[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Owner hard invariant: every explicit network/API/backend request is serialized
# and a new request may begin only after >= 5000 ms quiet time.
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

    $payload = [ordered]@{
        status = $Status
        error = $ErrorText
        exit_code = $ExitCode
        expected_release = $ExpectedTag
        pacing_ms = $NetworkMinGapMs
    }
    foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $payload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-BridgeApp {
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } } catch {}
    }
    Start-Sleep -Seconds 2
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
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
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
        if ($items.Count -gt 0) { return $items[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-ForCdpTarget {
    param([int]$Port,[int]$TimeoutSeconds = 60)

    # localhost discovery is HTTP too: never poll faster than 5 seconds.
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
        Start-Sleep -Seconds 5
    }
    return $null
}

function Send-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 180000
    )

    $payload = @{ id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Depth 50 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)

    try {
        [void]($Socket.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token).GetAwaiter().GetResult())

        while ($true) {
            $memory = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $bufferSegment = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
                    $receive = $Socket.ReceiveAsync($bufferSegment,$cts.Token).GetAwaiter().GetResult()
                    if ($receive.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'CDP websocket closed.'
                    }
                    $memory.Write($buffer,0,$receive.Count)
                } while (-not $receive.EndOfMessage)

                $message = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
                if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
                    return $message
                }
            }
            finally { $memory.Dispose() }
        }
    }
    finally { $cts.Dispose() }
}

function Invoke-CdpEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Expression,
        [string]$Stage,
        [int]$TimeoutMs = 240000
    )

    $response = Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    } -TimeoutMs $TimeoutMs
    $Id.Value++

    if ($null -ne $response.PSObject.Properties['error']) { throw ($Stage + ': CDP error') }
    if ($null -eq $response.result -or $null -eq $response.result.result) { throw ($Stage + ': missing result') }
    if ($null -ne $response.result.PSObject.Properties['exceptionDetails']) { throw ($Stage + ': JS exception') }

    $inner = $response.result.result
    if ($null -eq $inner.PSObject.Properties['value']) { throw ($Stage + ': missing by-value payload') }
    return $inner.value
}

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$probeId = [string]$request.args.probe_id
if ([string]::IsNullOrWhiteSpace($probeId) -or $probeId -notmatch '^[A-Za-z0-9_-]{8,96}$') {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'invalid_probe_id'
}

$statePath = Join-Path $StateRoot ($probeId + '.json')
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'phase_state_missing'
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$workerId = [string]$state.worker_id
if ([string]::IsNullOrWhiteSpace($workerId)) {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'worker_id_missing'
}

$workerIdJson = $workerId | ConvertTo-Json -Compress
$armedScheduleJson = ([string]$state.armed_schedule) | ConvertTo-Json -Compress
$beforeLastRunJson = $state.before_last_run | ConvertTo-Json -Compress

$port = Get-Random -Minimum 9400 -Maximum 9999
$cdpId = 1
$installedTag = $null

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) { throw 'installed_app_missing' }
    $release = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedTag = [string]$release.tag
    if ($installedTag -ne $ExpectedTag) { throw "installed_release_$installedTag" }

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe | Out-Null
    if ($null -eq (Wait-BridgeProcess -TimeoutSeconds 45)) { throw 'app_window_missing' }

    $target = Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if ($null -eq $target) { throw 'cdp_target_missing' }

    # Leave >5 seconds after the final localhost HTTP discovery request before
    # opening the diagnostic websocket.
    Start-Sleep -Seconds 10

    $targetItems = @($target)
    $wsUrl = if ($targetItems.Count -gt 0) { [string]$targetItems[0].webSocketDebuggerUrl } else { '' }
    if ([string]::IsNullOrWhiteSpace($wsUrl)) { throw 'cdp_websocket_url_missing' }
    $wsUri = [Uri]$wsUrl

    $socket = New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync($wsUri,[Threading.CancellationToken]::None).GetAwaiter().GetResult()

    # The websocket handshake is an explicit network operation too.
    Start-Sleep -Seconds 5

    $script = @"
(async()=>{
  const NETWORK_MIN_GAP_MS = 5000;
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  let __netTail = Promise.resolve();
  let __netLastFinishedAt = 0;

  function pacedFetch(input, init = {}) {
    const execute = async () => {
      const waitMs = Math.max(0, (__netLastFinishedAt + NETWORK_MIN_GAP_MS) - Date.now());
      if (waitMs > 0) await delay(waitMs);
      try {
        return await fetch(input, init);
      } finally {
        __netLastFinishedAt = Date.now();
      }
    };
    const current = __netTail.then(execute, execute);
    __netTail = current.then(() => undefined, () => undefined);
    return current;
  }

  async function authContext() {
    const response = await pacedFetch('/api/auth/session', {
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

  async function makeApi() {
    const auth = await authContext();
    const baseHeaders = {
      accept: 'application/json, text/plain, */*',
      authorization: 'Bearer ' + auth.token
    };
    if (auth.accountId) baseHeaders['chatgpt-account-id'] = auth.accountId;

    return {
      async get(path) {
        const response = await pacedFetch(path, {
          method: 'GET',
          credentials: 'include',
          cache: 'no-store',
          redirect: 'error',
          headers: { ...baseHeaders }
        });
        const raw = await response.text();
        let json = null;
        try { json = raw ? JSON.parse(raw) : null; } catch {}
        return { ok: response.ok, status: response.status, json };
      }
    };
  }

  function toMs(value) {
    if (value == null) return null;
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value < 1000000000000 ? value * 1000 : value;
    }
    const parsed = Date.parse(String(value));
    return Number.isFinite(parsed) ? parsed : null;
  }

  function scheduleShape(value) {
    const text = String(value || '');
    const lines = text.split(/\r?\n/).filter(Boolean);
    const freq = /\bFREQ=([^;\r\n]+)/i.exec(text);
    return {
      line_count: lines.length,
      has_dtstart: /\bDTSTART/i.test(text),
      dtstart_utc_z: /\bDTSTART:\d{8}T\d{6}Z\b/i.test(text),
      dtstart_tzid: /\bDTSTART;TZID=/i.test(text),
      has_rrule: /\bRRULE:/i.test(text),
      frequency: freq ? String(freq[1]).toUpperCase() : null,
      has_byhour: /\bBYHOUR=/i.test(text),
      has_byminute: /\bBYMINUTE=/i.test(text)
    };
  }

  function runInfo(x) {
    const now = Date.now();
    const next = Array.isArray(x?.next_run_times) ? x.next_run_times.map(toMs).filter(v => v != null) : [];
    const future = next.filter(v => v >= now).sort((a,b)=>a-b);
    const last = toMs(x?.last_run_time);
    return {
      timing_mode: x?.timing_mode ?? null,
      is_enabled: x?.is_enabled === true,
      default_timezone: x?.default_timezone ?? null,
      target_time_utc_present: x?.target_time_utc != null,
      next_run_count: next.length,
      future_next_run_count: future.length,
      first_future_delta_min: future.length ? Math.round((future[0] - now) / 60000) : null,
      last_run_present: last != null,
      last_run_age_min: last != null ? Math.round((now - last) / 60000) : null,
      schedule: scheduleShape(x?.schedule),
      schedule_component_keys: x?.schedule_components && typeof x.schedule_components === 'object'
        ? Object.keys(x.schedule_components).sort().slice(0,20)
        : []
    };
  }

  function latestShape(r) {
    const j = r?.json;
    return {
      http: r?.status ?? 0,
      ok: r?.ok === true,
      body_present: j != null,
      top_level_keys: j && typeof j === 'object'
        ? Object.keys(j).sort().slice(0,24)
        : []
    };
  }

  const workerId = $workerIdJson;
  const armedSchedule = $armedScheduleJson;
  const beforeLastRun = $beforeLastRunJson;
  const api = await makeApi();

  const scheduled = await api.get('/backend-api/automations?filter=scheduled');
  if (!scheduled.ok || !Array.isArray(scheduled.json?.items)) throw new Error('scheduled_http_' + scheduled.status);

  const paused = await api.get('/backend-api/automations?filter=paused');
  if (!paused.ok || !Array.isArray(paused.json?.items)) throw new Error('paused_http_' + paused.status);

  const finished = await api.get('/backend-api/automations?filter=finished');
  if (!finished.ok || !Array.isArray(finished.json?.items)) throw new Error('finished_http_' + finished.status);

  const sourceRows = [];
  for (const [source, items] of [
    ['scheduled', scheduled.json.items],
    ['paused', paused.json.items],
    ['finished', finished.json.items]
  ]) {
    for (const x of items) {
      if (x && typeof x.id === 'string') sourceRows.push({ source, x });
    }
  }

  const seen = new Set();
  const unique = [];
  for (const row of sourceRows) {
    if (seen.has(row.x.id)) continue;
    seen.add(row.x.id);
    unique.push(row);
  }

  const workerListRow = unique.find(r => r.x.id === workerId) || null;

  const comparatorCandidates = unique.filter(r => {
    const x = r.x;
    if (x.id === workerId) return false;
    return toMs(x.last_run_time) != null;
  });

  comparatorCandidates.sort((a,b) => {
    const score = row => {
      const x = row.x;
      let s = 0;
      if (x.is_enabled === true) s += 8;
      if (Array.isArray(x.next_run_times) && x.next_run_times.length > 0) s += 4;
      if (x.timing_mode === 'exact_schedule') s += 2;
      if (String(x.schedule || '').includes('RRULE:')) s += 1;
      return s;
    };
    return score(b) - score(a);
  });

  const comparatorRow = comparatorCandidates[0] || null;

  const workerDetail = await api.get('/backend-api/automation/' + encodeURIComponent(workerId));
  if (!workerDetail.ok || !workerDetail.json) throw new Error('worker_detail_http_' + workerDetail.status);

  let comparatorDetail = null;
  let comparatorLatest = null;
  if (comparatorRow) {
    comparatorDetail = await api.get('/backend-api/automation/' + encodeURIComponent(comparatorRow.x.id));
    if (!comparatorDetail.ok || !comparatorDetail.json) {
      throw new Error('comparator_detail_http_' + comparatorDetail.status);
    }
  }

  const workerLatest = await api.get(
    '/backend-api/automation/' + encodeURIComponent(workerId) + '/latest_backing_run?include_snapshot=true'
  );

  if (comparatorRow) {
    comparatorLatest = await api.get(
      '/backend-api/automation/' + encodeURIComponent(comparatorRow.x.id) + '/latest_backing_run?include_snapshot=true'
    );
  }

  const sample = unique.slice(0,12).map(row => ({
    source: row.source,
    state: runInfo(row.x)
  }));

  return {
    pass: true,
    counts: {
      scheduled: scheduled.json.items.length,
      paused: paused.json.items.length,
      finished: finished.json.items.length,
      unique: unique.length
    },
    phase_worker: {
      found_in_lists: !!workerListRow,
      list_source: workerListRow?.source ?? null,
      current: runInfo(workerDetail.json),
      latest: latestShape(workerLatest),
      before_last_run_present: beforeLastRun != null,
      armed_schedule: scheduleShape(armedSchedule)
    },
    comparator: comparatorRow ? {
      found: true,
      list_source: comparatorRow.source,
      current: runInfo(comparatorDetail.json),
      latest: latestShape(comparatorLatest)
    } : {
      found: false
    },
    sample
  };
})()
"@

    $value = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'scheduled-timing-paced'
    $json = $value | ConvertTo-Json -Depth 30 -Compress
    Write-Host ('SCHEDULED_TIMING_PACED=' + $json)

    Write-ProjectResult -Status 'evidence' -ExitCode 20 -ErrorText $json -Extra @{
        installed_tag = $installedTag
        probe_id = $probeId
        worker_id_present = $true
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
        probe_id = $probeId
    }
}
finally {
    if ($null -ne $socket) { try { $socket.Dispose() } catch {} }
    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}
