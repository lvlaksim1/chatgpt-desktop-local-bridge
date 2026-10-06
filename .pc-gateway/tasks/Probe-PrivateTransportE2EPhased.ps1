[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Owner hard invariant: every explicit network/API/backend request is serialized
# and the next request may begin only after at least 5000 ms of quiet time.
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
        pacing_ms = $NetworkMinGapMs
    }

    foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $payload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
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

    # /json is an HTTP request too, so even localhost discovery obeys the 5 s rule.
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

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 50 -Compress

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
        [int]$TimeoutMs = 180000
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

    if ($null -ne $response.result.PSObject.Properties['exceptionDetails']) {
        throw ($Stage + ': JS exception: ' + ($response.result.exceptionDetails | ConvertTo-Json -Depth 10 -Compress))
    }

    $inner = $response.result.result
    if ($null -ne $inner.PSObject.Properties['exceptionDetails']) {
        throw ($Stage + ': JS exception: ' + ($inner.exceptionDetails | ConvertTo-Json -Depth 10 -Compress))
    }

    if ($null -eq $inner.PSObject.Properties['value']) {
        throw ($Stage + ': missing by-value payload')
    }

    return $inner.value
}

function Add-OrSetProperty {
    param(
        [object]$Object,
        [string]$Name,
        $Value
    )

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Write-State {
    param(
        [object]$State,
        [string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $State | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-State {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "E2E state file is missing: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Open-DiagnosticSession {
    param(
        [ref]$SocketRef,
        [ref]$CdpIdRef
    )

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses

    $port = Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe | Out-Null

    $app = Wait-BridgeProcess -TimeoutSeconds 45
    if ($null -eq $app) { throw 'Application main window did not appear.' }

    $target = Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if ($null -eq $target) { throw 'ChatGPT WebView2 CDP target did not appear.' }

    # Avoid adding an extra Page.navigate request. The ordinary app already opened chatgpt.com.
    # Give normal page loading time to settle before scripted backend traffic begins.
    Start-Sleep -Seconds 10

    $s = New-Object System.Net.WebSockets.ClientWebSocket
    $s.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $SocketRef.Value = $s
    $CdpIdRef.Value = 1
}

function Close-DiagnosticSession {
    if ($null -ne $script:socket) {
        try { $script:socket.Dispose() } catch {}
        $script:socket = $null
    }

    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        $oldBrowserArgs,
        'Process')
}

function Get-PacingPrelude {
    return @"
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

    async function jsonApi(method, path, body) {
      const headers = { ...baseHeaders };
      const init = {
        method,
        credentials: 'include',
        redirect: 'error',
        cache: 'no-store',
        headers
      };

      if (body !== undefined) {
        headers['content-type'] = 'application/json';
        init.body = JSON.stringify(body);
      }

      const response = await pacedFetch(path, init);
      const raw = await response.text();
      let json = null;
      try { json = raw ? JSON.parse(raw) : null; } catch {}
      return { ok: response.ok, status: response.status, json, raw };
    }

    async function textApi(method, path, body) {
      const headers = { ...baseHeaders };
      const init = {
        method,
        credentials: 'include',
        redirect: 'error',
        cache: 'no-store',
        headers
      };

      if (body !== undefined) {
        headers['content-type'] = 'application/json';
        init.body = JSON.stringify(body);
      }

      const response = await pacedFetch(path, init);
      return { ok: response.ok, status: response.status, raw: await response.text() };
    }

    return { jsonApi, textApi, baseHeaders };
  }

  function parseNdjson(raw) {
    const items = [];
    for (const line of String(raw || '').split(/\r?\n/)) {
      if (!line.trim()) continue;
      try { items.push(JSON.parse(line)); } catch { throw new Error('invalid_ndjson'); }
      if (items.length > 256) throw new Error('ndjson_too_large');
    }
    return items;
  }
"@
}

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$phase = ''
$probeId = ''
$waitSeconds = 0

if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['phase']) {
    $phase = ([string]$request.args.phase).Trim().ToUpperInvariant()
}
if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['probe_id']) {
    $probeId = ([string]$request.args.probe_id).Trim()
}
if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['wait_seconds']) {
    $waitSeconds = [Math]::Max(0, [Math]::Min(900, [int]$request.args.wait_seconds))
}

if ($phase -notin @('A', 'B', 'C')) {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'args.phase must be A, B or C.'
}

if ($probeId -notmatch '^[A-Za-z0-9_-]{8,96}$') {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText 'args.probe_id must be 8-96 safe characters.'
}

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
$statePath = Join-Path $StateRoot ($probeId + '.json')
$cdpId = 1
$installedTag = $null

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

    if ($waitSeconds -gt 0) {
        Start-Sleep -Seconds $waitSeconds
    }

    if ($phase -eq 'A') {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            throw "State already exists for probe_id '$probeId'. Refusing duplicate Phase A."
        }

        $messageId = 'msg-' + [Guid]::NewGuid().ToString('N')
        $payload = 'FULL-FILE-PING-' + [Guid]::NewGuid().ToString('N').Substring(0, 16).ToUpperInvariant()
        $requestName = $probeId + '-request.json'
        $resultName = $probeId + '-result.json'

        $state = [pscustomobject][ordered]@{
            schema = 'private-transport-e2e-phased-v1'
            probe_id = $probeId
            stage = 'created'
            created_utc = [DateTime]::UtcNow.ToString('o')
            network_min_gap_ms = $NetworkMinGapMs
            message_id = $messageId
            payload = $payload
            request_name = $requestName
            result_name = $resultName
            worker_id = $null
            original = $null
            request_file_id = $null
            request_library_id = $null
            request_directory_id = $null
            armed_schedule = $null
            armed_timing_mode = $null
            armed_target_time_utc_present = $false
            armed_next_run_count = 0
            armed_future_next_run_count = 0
            armed_first_future_delta_sec = $null
            before_last_run = $null
            result_library_id = $null
            result_file_id = $null
            last_observation = $null
            error = $null
        }
        Write-State -State $state -Path $statePath

        Open-DiagnosticSession -SocketRef ([ref]$script:socket) -CdpIdRef ([ref]$cdpId)

        $pacing = Get-PacingPrelude
        $prepareScript = @"
(async () => {
$pacing
  const api = await makeApi();

  const paused = await api.jsonApi('GET', '/backend-api/automations?filter=paused');
  if (!paused.ok || !Array.isArray(paused.json?.items)) {
    throw new Error('paused_list_http_' + paused.status);
  }

  const candidates = paused.json.items.filter(x =>
    x &&
    x.is_enabled === false &&
    x.timing_mode === 'exact_schedule' &&
    typeof x.id === 'string' &&
    typeof x.prompt === 'string' &&
    typeof x.schedule === 'string' &&
    typeof x.conversation_id === 'string' &&
    !String(x.prompt || '').includes('PRIVATE TRANSPORT E2E WORKER') &&
    !String(x.title || '').startsWith('bridge-e2e-')
  );

  candidates.sort((a, b) => {
    const score = x => /probe|transport|library|ndrm|srrm|scheduled/i.test(String(x.title || '')) ? 1 : 0;
    return score(b) - score(a);
  });

  const row = candidates[0];
  if (!row) return { ok: false, code: 'no_safe_worker' };

  const detail = await api.jsonApi('GET', '/backend-api/automation/' + encodeURIComponent(row.id));
  if (!detail.ok || !detail.json) throw new Error('worker_read_http_' + detail.status);

  const x = detail.json;
  return {
    ok: true,
    worker: {
      id: x.id,
      title: String(x.title || '').slice(0, 160),
      prompt: String(x.prompt || ''),
      schedule: String(x.schedule || ''),
      default_timezone: x.default_timezone ?? 'UTC',
      display_emoji: x.display_emoji ?? null,
      notifications_enabled: x.notifications_enabled === true,
      email_enabled: x.email_enabled === true,
      model: x.model ?? null,
      reasoning_effort: x.reasoning_effort ?? null,
      timing_mode: x.timing_mode ?? null,
      is_enabled: x.is_enabled === true,
      conversation_id: x.conversation_id ?? null,
      last_run_time: x.last_run_time ?? null
    }
  };
})()
"@

        $prepared = Invoke-CdpEval -Socket $script:socket -Id ([ref]$cdpId) -Expression $prepareScript -Stage 'phase-a-snapshot' -TimeoutMs 180000
        if (-not [bool]$prepared.ok) {
            throw ('Phase A could not select worker: ' + [string]$prepared.code)
        }

        Add-OrSetProperty -Object $state -Name 'worker_id' -Value ([string]$prepared.worker.id)
        Add-OrSetProperty -Object $state -Name 'original' -Value $prepared.worker
        Add-OrSetProperty -Object $state -Name 'before_last_run' -Value $prepared.worker.last_run_time
        Add-OrSetProperty -Object $state -Name 'stage' -Value 'snapshot_persisted'
        Write-State -State $state -Path $statePath

        # CDP Runtime.evaluate is also an explicit command; keep a quiet gap before the next one.
        Start-Sleep -Seconds 5

        $stateJson = $state | ConvertTo-Json -Depth 60 -Compress
        $mutationScript = @"
(async () => {
$pacing
  const state = $stateJson;
  const api = await makeApi();

  function saveBody(current, prompt, schedule) {
    const body = {
      default_timezone: current.default_timezone,
      email_enabled: false,
      is_enabled: false,
      jawbone_id: current.id,
      notifications_enabled: false,
      prompt,
      emoji: current.display_emoji,
      schedule,
      timing_mode: 0,
      title: current.title
    };
    if (current.model != null) body.model = current.model;
    if (current.reasoning_effort != null) body.reasoning_effort = current.reasoning_effort;
    return body;
  }

  function scheduleAt(ms) {
    const d = new Date(ms);
    d.setUTCSeconds(0, 0);
    const p = n => String(n).padStart(2, '0');
    const stamp = d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) +
      'T' + p(d.getUTCHours()) + p(d.getUTCMinutes()) + '00';
    return 'BEGIN:VEVENT\nDTSTART;TZID=UTC:' + stamp + '\nEND:VEVENT';
  }

  function toMs(value) {
    if (value == null) return null;
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value < 1000000000000 ? value * 1000 : value;
    }
    const parsed = Date.parse(String(value));
    return Number.isFinite(parsed) ? parsed : null;
  }

  const requestText = JSON.stringify({
    protocol: 'FULL-FILE-DATAPLANE-V3-PACED',
    message_id: state.message_id,
    command: 'ECHO_PAYLOAD',
    payload: state.payload
  });
  const requestBytes = new TextEncoder().encode(requestText);

  const prepared = await api.jsonApi('POST', '/backend-api/files', {
    file_name: state.request_name,
    file_size: requestBytes.byteLength,
    use_case: 'ace_upload',
    timezone_offset_min: new Date().getTimezoneOffset(),
    reset_rate_limits: false,
    supports_direct_azure_multipart: false,
    mime_type: 'application/json',
    entry_surface: 'chat_composer',
    store_in_library: true,
    library_persistence_mode: 'required'
  });

  if (!prepared.ok || prepared.json?.status !== 'success' ||
      typeof prepared.json?.file_id !== 'string' ||
      typeof prepared.json?.upload_url !== 'string') {
    throw new Error('prepare_http_' + prepared.status);
  }

  const fileId = prepared.json.file_id;
  const uploadUrl = new URL(prepared.json.upload_url);
  if (uploadUrl.protocol !== 'https:' ||
      !uploadUrl.hostname.endsWith('.oaiusercontent.com') ||
      !uploadUrl.search) {
    throw new Error('unsafe_upload_url');
  }

  const aws = Array.from(uploadUrl.searchParams.keys())
    .some(key => key.toLowerCase() === 'x-amz-algorithm');
  const uploadHeaders = aws
    ? { 'Content-Type': 'application/json' }
    : {
        'Content-Type': 'application/json',
        'x-ms-blob-type': 'BlockBlob',
        'x-ms-version': '2020-04-08'
      };

  const uploaded = await pacedFetch(uploadUrl.href, {
    method: 'PUT',
    credentials: 'omit',
    redirect: 'error',
    headers: uploadHeaders,
    body: requestBytes
  });
  if (!uploaded.ok) throw new Error('upload_http_' + uploaded.status);

  const processed = await api.textApi('POST', '/backend-api/files/process_upload_stream', {
    file_id: fileId,
    file_name: state.request_name,
    use_case: 'ace_upload',
    index_for_retrieval: true,
    entry_surface: 'chat_composer',
    library_persistence_mode: 'required',
    metadata: {
      store_in_library: true,
      is_temporary_chat: false,
      is_project_thread: false
    }
  });
  if (!processed.ok) throw new Error('process_http_' + processed.status);

  const processEvents = parseNdjson(processed.raw);
  const final = processEvents.slice().reverse().find(x =>
    x?.event === 'file.processing.completed' &&
    x?.file_id === fileId &&
    x?.progress === 100
  );
  if (!final) throw new Error('processing_unconfirmed');

  const libraryId = typeof final?.extra?.metadata_object_id === 'string'
    ? final.extra.metadata_object_id
    : null;
  if (!libraryId) throw new Error('request_library_id_missing');

  const downloaded = await pacedFetch(
    '/api/library/files/' + encodeURIComponent(libraryId) + '/download',
    { method: 'GET', credentials: 'include', redirect: 'follow', cache: 'no-store' }
  );
  if (!downloaded.ok) throw new Error('request_download_http_' + downloaded.status);
  const downloadedText = await downloaded.text();
  if (downloadedText !== requestText) throw new Error('request_readback_mismatch');

  const currentResult = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );
  if (!currentResult.ok || !currentResult.json) {
    throw new Error('worker_pre_mutation_read_http_' + currentResult.status);
  }

  const current = currentResult.json;
  if (current.is_enabled !== false) throw new Error('worker_not_paused_before_mutation');

  const workerPrompt = [
    'PRIVATE TRANSPORT E2E WORKER V3 PACED.',
    'Do not use conversation messages as transport input.',
    'Use ChatGPT Files/Library capabilities.',
    'Find the Library file named exactly: ' + state.request_name,
    'Read and parse its JSON. Require protocol FULL-FILE-DATAPLANE-V3-PACED and command ECHO_PAYLOAD.',
    'Create a JSON file named exactly: ' + state.result_name,
    'The JSON must contain protocol, message_id, payload and ack.',
    'protocol must be FULL-FILE-DATAPLANE-V3-PACED.',
    'message_id and payload must exactly match the request file.',
    'ack must equal WORKER-ACK- plus the payload.',
    'Make the result file durably available in ChatGPT Library before finishing.',
    'Final textual response may be only WORKER_DONE.'
  ].join('\n');

  const armedSchedule = scheduleAt(Date.now() + 6 * 60 * 1000);
  const saved = await api.jsonApi(
    'POST',
    '/backend-api/automations/save',
    saveBody(current, workerPrompt, armedSchedule)
  );
  if (!saved.ok) throw new Error('worker_save_http_' + saved.status);

  const afterSave = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );
  if (!afterSave.ok || !afterSave.json ||
      afterSave.json.prompt !== workerPrompt ||
      afterSave.json.schedule !== armedSchedule ||
      afterSave.json.is_enabled !== false) {
    throw new Error('worker_save_readback_mismatch');
  }

  const enabled = await api.jsonApi(
    'POST',
    '/backend-api/automations/set_status',
    { jawbone_id: state.worker_id, is_enabled: true }
  );
  if (!enabled.ok) throw new Error('worker_enable_http_' + enabled.status);

  const afterEnable = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );

  const nextRuns = Array.isArray(afterEnable.json?.next_run_times)
    ? afterEnable.json.next_run_times.map(toMs).filter(v => v != null)
    : [];
  const nowAfterEnable = Date.now();
  const futureRuns = nextRuns.filter(v => v > nowAfterEnable).sort((a, b) => a - b);
  const firstFutureDeltaSec = futureRuns.length
    ? Math.round((futureRuns[0] - nowAfterEnable) / 1000)
    : null;

  if (!afterEnable.ok || !afterEnable.json ||
      afterEnable.json.is_enabled !== true ||
      afterEnable.json.prompt !== workerPrompt ||
      afterEnable.json.schedule !== armedSchedule ||
      afterEnable.json.timing_mode !== 'exact_schedule' ||
      afterEnable.json.target_time_utc == null ||
      futureRuns.length < 1 ||
      firstFutureDeltaSec == null ||
      firstFutureDeltaSec < 60 ||
      firstFutureDeltaSec > 15 * 60) {
    throw new Error('worker_enable_schedule_readback_mismatch');
  }

  return {
    pass: true,
    request_file_id: fileId,
    request_library_id: libraryId,
    request_directory_id: final?.extra?.parent_directory_id ?? null,
    armed_schedule: armedSchedule,
    worker_prompt_hash_input_length: workerPrompt.length,
    enable_http: enabled.status,
    timing_mode: afterEnable.json.timing_mode,
    target_time_utc_present: afterEnable.json.target_time_utc != null,
    next_run_count: nextRuns.length,
    future_next_run_count: futureRuns.length,
    first_future_delta_sec: firstFutureDeltaSec
  };
})()
"@

        $mutation = Invoke-CdpEval -Socket $script:socket -Id ([ref]$cdpId) -Expression $mutationScript -Stage 'phase-a-arm' -TimeoutMs 240000

        $mutationProperties = @($mutation.PSObject.Properties.Name)
        $requiredMutationProperties = @(
            'pass','request_file_id','request_library_id','armed_schedule','enable_http',
            'timing_mode','target_time_utc_present','next_run_count','future_next_run_count','first_future_delta_sec'
        )
        $missingMutationProperties = @($requiredMutationProperties | Where-Object { $_ -notin $mutationProperties })
        if ($missingMutationProperties.Count -gt 0) {
            throw ('Phase A mutation result missing fields: ' + ($missingMutationProperties -join ',') +
                '; shape=' + ($mutationProperties -join ','))
        }
        if (-not [bool]$mutation.pass) {
            throw 'Phase A mutation result did not report pass=true.'
        }

        Add-OrSetProperty -Object $state -Name 'stage' -Value 'armed'
        Add-OrSetProperty -Object $state -Name 'request_file_id' -Value ([string]$mutation.request_file_id)
        Add-OrSetProperty -Object $state -Name 'request_library_id' -Value ([string]$mutation.request_library_id)
        Add-OrSetProperty -Object $state -Name 'request_directory_id' -Value $mutation.request_directory_id
        Add-OrSetProperty -Object $state -Name 'armed_schedule' -Value ([string]$mutation.armed_schedule)
        Add-OrSetProperty -Object $state -Name 'armed_timing_mode' -Value ([string]$mutation.timing_mode)
        Add-OrSetProperty -Object $state -Name 'armed_target_time_utc_present' -Value ([bool]$mutation.target_time_utc_present)
        Add-OrSetProperty -Object $state -Name 'armed_next_run_count' -Value ([int]$mutation.next_run_count)
        Add-OrSetProperty -Object $state -Name 'armed_future_next_run_count' -Value ([int]$mutation.future_next_run_count)
        Add-OrSetProperty -Object $state -Name 'armed_first_future_delta_sec' -Value ([int]$mutation.first_future_delta_sec)
        Add-OrSetProperty -Object $state -Name 'phase_a_completed_utc' -Value ([DateTime]::UtcNow.ToString('o'))
        Write-State -State $state -Path $statePath

        Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
            installed_tag = $installedTag
            phase = 'A'
            probe_id = $probeId
            stage = 'armed'
            worker_id_present = $true
            request_file_id_present = $true
            request_library_id_present = $true
            enable_http = [int]$mutation.enable_http
            timing_mode = [string]$mutation.timing_mode
            target_time_utc_present = [bool]$mutation.target_time_utc_present
            next_run_count = [int]$mutation.next_run_count
            future_next_run_count = [int]$mutation.future_next_run_count
            first_future_delta_sec = [int]$mutation.first_future_delta_sec
            state_path = $statePath
        }
    }

    if ($phase -eq 'B') {
        $state = Read-State -Path $statePath
        if ([string]$state.stage -notin @('armed', 'waiting', 'result_verified')) {
            throw "Phase B cannot run from state '$($state.stage)'."
        }

        Open-DiagnosticSession -SocketRef ([ref]$script:socket) -CdpIdRef ([ref]$cdpId)

        $pacing = Get-PacingPrelude
        $stateJson = $state | ConvertTo-Json -Depth 60 -Compress

        $observeScript = @"
(async () => {
$pacing
  const state = $stateJson;
  const api = await makeApi();

  const task = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );
  if (!task.ok || !task.json) throw new Error('worker_read_http_' + task.status);

  const library = await api.jsonApi('POST', '/backend-api/files/library', { limit: 100 });
  if (!library.ok || !Array.isArray(library.json?.items)) {
    throw new Error('library_list_http_' + library.status);
  }

  const resultItem = library.json.items.find(x =>
    x &&
    x.trashed_at == null &&
    x.file_name === state.result_name
  ) || null;

  let resultVerified = false;
  let resultLibraryId = null;
  let resultFileId = null;
  let resultDownloadStatus = 0;

  if (resultItem) {
    resultLibraryId = resultItem.id ?? null;
    resultFileId = resultItem.file_id ?? null;

    const downloaded = await pacedFetch(
      '/api/library/files/' + encodeURIComponent(resultItem.id) + '/download',
      { method: 'GET', credentials: 'include', redirect: 'follow', cache: 'no-store' }
    );
    resultDownloadStatus = downloaded.status;

    if (downloaded.ok) {
      try {
        const resultJson = JSON.parse(await downloaded.text());
        resultVerified =
          resultJson?.protocol === 'FULL-FILE-DATAPLANE-V3-PACED' &&
          resultJson?.message_id === state.message_id &&
          resultJson?.payload === state.payload &&
          resultJson?.ack === 'WORKER-ACK-' + state.payload;
      } catch {}
    }
  }

  const latest = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id) +
      '/latest_backing_run?include_snapshot=true'
  );

  return {
    pass: resultVerified,
    worker_enabled: task.json.is_enabled === true,
    run_advanced:
      !!task.json.last_run_time &&
      task.json.last_run_time !== (state.before_last_run ?? null),
    last_run_present: !!task.json.last_run_time,
    latest_run_http: latest.status,
    result_found: !!resultItem,
    result_verified: resultVerified,
    result_library_id: resultLibraryId,
    result_file_id: resultFileId,
    result_download_http: resultDownloadStatus
  };
})()
"@

        $observation = Invoke-CdpEval -Socket $script:socket -Id ([ref]$cdpId) -Expression $observeScript -Stage 'phase-b-observe' -TimeoutMs 180000

        $obs = [pscustomobject][ordered]@{
            observed_utc = [DateTime]::UtcNow.ToString('o')
            worker_enabled = [bool]$observation.worker_enabled
            run_advanced = [bool]$observation.run_advanced
            last_run_present = [bool]$observation.last_run_present
            latest_run_http = [int]$observation.latest_run_http
            result_found = [bool]$observation.result_found
            result_verified = [bool]$observation.result_verified
            result_download_http = [int]$observation.result_download_http
        }

        Add-OrSetProperty -Object $state -Name 'last_observation' -Value $obs

        if ([bool]$observation.result_verified) {
            Add-OrSetProperty -Object $state -Name 'stage' -Value 'result_verified'
            Add-OrSetProperty -Object $state -Name 'result_library_id' -Value ([string]$observation.result_library_id)
            Add-OrSetProperty -Object $state -Name 'result_file_id' -Value ([string]$observation.result_file_id)
        }
        else {
            Add-OrSetProperty -Object $state -Name 'stage' -Value 'waiting'
        }

        Write-State -State $state -Path $statePath

        Write-ProjectResult -Status ($(if ([bool]$observation.result_verified) { 'pass' } else { 'pending' })) -ExitCode 0 -Extra @{
            installed_tag = $installedTag
            phase = 'B'
            probe_id = $probeId
            stage = [string]$state.stage
            run_advanced = [bool]$observation.run_advanced
            latest_run_http = [int]$observation.latest_run_http
            result_found = [bool]$observation.result_found
            result_verified = [bool]$observation.result_verified
            result_download_http = [int]$observation.result_download_http
        }
    }

    if ($phase -eq 'C') {
        $state = Read-State -Path $statePath
        if ($null -eq $state.original -or [string]::IsNullOrWhiteSpace([string]$state.worker_id)) {
            throw 'Recovery snapshot is incomplete. Refusing cleanup mutation.'
        }

        Open-DiagnosticSession -SocketRef ([ref]$script:socket) -CdpIdRef ([ref]$cdpId)

        $pacing = Get-PacingPrelude
        $stateJson = $state | ConvertTo-Json -Depth 60 -Compress

        $cleanupScript = @"
(async () => {
$pacing
  const state = $stateJson;
  const api = await makeApi();

  function saveBody(current) {
    const original = state.original;
    const body = {
      default_timezone: original.default_timezone,
      email_enabled: original.email_enabled === true,
      is_enabled: false,
      jawbone_id: current.id,
      notifications_enabled: original.notifications_enabled === true,
      prompt: original.prompt,
      emoji: original.display_emoji,
      schedule: original.schedule,
      timing_mode: 0,
      title: original.title
    };
    if (original.model != null) body.model = original.model;
    if (original.reasoning_effort != null) body.reasoning_effort = original.reasoning_effort;
    return body;
  }

  async function softDelete(item) {
    if (!item?.id || !item?.file_id) return { status: 0, completed: false };

    const url = new URL(
      '/backend-api/files/library/files/' + encodeURIComponent(item.id) + '/delete_stream',
      location.origin
    );
    url.searchParams.set('file_id', item.file_id);
    if (item.directory_id != null) {
      url.searchParams.set('parent_directory_id', String(item.directory_id));
    }
    url.searchParams.set('file_name', item.file_name || '');
    url.searchParams.set('soft_delete', 'true');

    const r = await api.textApi('POST', url.pathname + url.search);
    const events = parseNdjson(r.raw);
    return {
      status: r.status,
      completed: events.some(x => x?.event === 'file.deletion.completed')
    };
  }

  let task = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );
  if (!task.ok || !task.json) throw new Error('worker_read_http_' + task.status);

  let disabled = task.json.is_enabled === false;
  let disableHttp = 0;

  if (!disabled) {
    const d = await api.jsonApi(
      'POST',
      '/backend-api/automations/set_status',
      { jawbone_id: state.worker_id, is_enabled: false }
    );
    disableHttp = d.status;
    if (!d.ok) throw new Error('worker_disable_http_' + d.status);

    task = await api.jsonApi(
      'GET',
      '/backend-api/automation/' + encodeURIComponent(state.worker_id)
    );
    if (!task.ok || !task.json || task.json.is_enabled !== false) {
      throw new Error('worker_disable_readback_mismatch');
    }
    disabled = true;
  }

  const restored = await api.jsonApi(
    'POST',
    '/backend-api/automations/save',
    saveBody(task.json)
  );
  if (!restored.ok) throw new Error('worker_restore_http_' + restored.status);

  const restoredRead = await api.jsonApi(
    'GET',
    '/backend-api/automation/' + encodeURIComponent(state.worker_id)
  );
  if (!restoredRead.ok || !restoredRead.json) {
    throw new Error('worker_restore_read_http_' + restoredRead.status);
  }

  const taskRestored =
    restoredRead.json.is_enabled === false &&
    restoredRead.json.prompt === state.original.prompt &&
    restoredRead.json.schedule === state.original.schedule &&
    (restoredRead.json.notifications_enabled === true) === (state.original.notifications_enabled === true) &&
    (restoredRead.json.email_enabled === true) === (state.original.email_enabled === true);

  if (!taskRestored) throw new Error('worker_restore_readback_mismatch');

  const library = await api.jsonApi('POST', '/backend-api/files/library', { limit: 100 });
  if (!library.ok || !Array.isArray(library.json?.items)) {
    throw new Error('library_list_http_' + library.status);
  }

  const candidates = library.json.items.filter(x =>
    x &&
    x.trashed_at == null &&
    (x.file_name === state.request_name || x.file_name === state.result_name)
  );

  const deleted = [];
  for (const item of candidates) {
    const d = await softDelete(item);
    deleted.push({
      name: item.file_name,
      status: d.status,
      completed: d.completed
    });
  }

  const verify = await api.jsonApi('POST', '/backend-api/files/library', { limit: 100 });
  if (!verify.ok || !Array.isArray(verify.json?.items)) {
    throw new Error('library_verify_http_' + verify.status);
  }

  const leftovers = verify.json.items.filter(x =>
    x &&
    x.trashed_at == null &&
    (x.file_name === state.request_name || x.file_name === state.result_name)
  );

  return {
    pass: taskRestored && deleted.every(x => x.completed) && leftovers.length === 0,
    disable_http: disableHttp,
    restore_http: restored.status,
    task_restored: taskRestored,
    deleted,
    leftovers: leftovers.length
  };
})()
"@

        $cleanup = Invoke-CdpEval -Socket $script:socket -Id ([ref]$cdpId) -Expression $cleanupScript -Stage 'phase-c-cleanup' -TimeoutMs 240000

        Add-OrSetProperty -Object $state -Name 'stage' -Value ($(if ([bool]$cleanup.pass) { 'complete' } else { 'cleanup_incomplete' }))
        Add-OrSetProperty -Object $state -Name 'phase_c_completed_utc' -Value ([DateTime]::UtcNow.ToString('o'))
        Write-State -State $state -Path $statePath

        if (-not [bool]$cleanup.pass) {
            throw 'Phase C cleanup assertions failed.'
        }

        Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
            installed_tag = $installedTag
            phase = 'C'
            probe_id = $probeId
            stage = 'complete'
            task_restored = [bool]$cleanup.task_restored
            deleted_count = @($cleanup.deleted).Count
            leftovers = [int]$cleanup.leftovers
        }
    }
}
catch {
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = Read-State -Path $statePath
            Add-OrSetProperty -Object $state -Name 'error' -Value $_.Exception.Message
            Add-OrSetProperty -Object $state -Name 'last_error_utc' -Value ([DateTime]::UtcNow.ToString('o'))
            Write-State -State $state -Path $statePath
        }
    }
    catch {}

    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
        phase = $phase
        probe_id = $probeId
        state_path = $statePath
    }
}
finally {
    Close-DiagnosticSession
}