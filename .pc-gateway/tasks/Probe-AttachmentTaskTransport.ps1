[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$NetworkGapSeconds = 5
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ProcessName = 'ChatGptDesktopLocalBridge'
$oldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$socket = $null

function Write-Result {
    param([string]$Status, [int]$ExitCode, [hashtable]$Data = @{}, [string]$ErrorText = '')
    $payload = [ordered]@{
        status = $Status
        exit_code = $ExitCode
        error = $ErrorText
        network_min_gap_seconds = $NetworkGapSeconds
    }
    foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-App {
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } } catch {}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Stop-WebViews {
    $needle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach ($item in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $needle + '*') })) {
        try { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds = 45) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
        if ($p.Count -gt 0) { return $p[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-CdpTarget([int]$Port, [int]$TimeoutSeconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json') -UseBasicParsing -TimeoutSec 2)
            $target = @($targets | Where-Object {
                $_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
            } | Select-Object -First 1)
            if ($target.Count -gt 0) { return $target[0] }
        } catch {}
        Start-Sleep -Seconds $NetworkGapSeconds
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
    $payload = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 40 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try {
        [void]($Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult())
        while ($true) {
            $mem = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $seg = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
                    $rx = $Socket.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
                    if ($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'CDP websocket closed.' }
                    $mem.Write($buffer, 0, $rx.Count)
                } while (-not $rx.EndOfMessage)
                $msg = ([Text.Encoding]::UTF8.GetString($mem.ToArray()) | ConvertFrom-Json)
                if ($null -ne $msg.PSObject.Properties['id'] -and [int]$msg.id -eq $Id) { return $msg }
            } finally { $mem.Dispose() }
        }
    } finally { $cts.Dispose() }
}

function Eval {
    param([string]$Expression, [string]$Stage, [int]$Id = 1)
    $r = Send-CdpCommand -Socket $script:socket -Id $Id -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }
    if ($null -ne $r.PSObject.Properties['error']) { throw ($Stage + ': ' + ($r.error | ConvertTo-Json -Compress)) }
    if ($null -ne $r.result.PSObject.Properties['exceptionDetails']) { throw ($Stage + ': JS exception') }
    return $r.result.result.value
}

function Open-Session {
    Stop-App
    Stop-WebViews
    $port = Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'), 'Process')
    Start-Process -FilePath $AppExe | Out-Null
    if ($null -eq (Wait-App)) { throw 'Application window did not appear.' }
    $target = Wait-CdpTarget -Port $port
    if ($null -eq $target) { throw 'ChatGPT WebView2 target did not appear.' }
    Start-Sleep -Seconds 10
    $s = New-Object Net.WebSockets.ClientWebSocket
    $s.ConnectAsync([Uri][string]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $script:socket = $s
}

function Close-Session {
    if ($null -ne $script:socket) { try { $script:socket.Dispose() } catch {}; $script:socket = $null }
    try { Stop-App } catch {}
    try { Stop-WebViews } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', $oldBrowserArgs, 'Process')
}

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$phase = 'A'
if ($null -ne $request.args -and $null -ne $request.args.PSObject.Properties['phase']) {
    $phase = ([string]$request.args.phase).Trim().ToUpperInvariant()
}
if ($phase -ne 'A') { Write-Result -Status 'fail' -ExitCode 31 -ErrorText 'Only phase A is implemented in this revision.' }

if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
    Write-Result -Status 'fail' -ExitCode 32 -ErrorText "Installed app not found: $AppExe"
}

$probeId = 'attach-' + [Guid]::NewGuid().ToString('N').Substring(0, 16)
$probeFile = Join-Path $env:TEMP ($probeId + '.json')
$probeText = '{"schema":"local-bridge-attachment-probe-v1","probe_id":"' + $probeId + '","russian":"Проверка кириллицы: мост получает файл без искажений","marker":"FILE-ATTACHMENT-PROBE"}'
[IO.File]::WriteAllText($probeFile, $probeText, [Text.UTF8Encoding]::new($false))
$probeHash = (Get-FileHash -LiteralPath $probeFile -Algorithm SHA256).Hash.ToLowerInvariant()
$probeBytes = (Get-Item -LiteralPath $probeFile).Length

try {
    Open-Session

    $js = @"
(async () => {
  const GAP = 5000;
  let last = 0;
  const delay = ms => new Promise(r => setTimeout(r, ms));
  async function pacedFetch(path, init) {
    const wait = Math.max(0, last + GAP - Date.now());
    if (wait) await delay(wait);
    try { return await fetch(path, init); }
    finally { last = Date.now(); }
  }

  const authResponse = await pacedFetch('/api/auth/session', {
    credentials: 'include', cache: 'no-store', redirect: 'error',
    headers: { accept: 'application/json' }
  });
  if (!authResponse.ok) throw new Error('auth_' + authResponse.status);
  const session = await authResponse.json();
  const token = session?.accessToken || '';
  const accountId = session?.account?.id || '';
  if (!token) throw new Error('missing_access_token');

  const headers = { accept: 'application/json, text/plain, */*', authorization: 'Bearer ' + token };
  if (accountId) headers['chatgpt-account-id'] = accountId;

  const pausedResponse = await pacedFetch('/backend-api/automations?filter=paused', {
    method: 'GET', credentials: 'include', cache: 'no-store', redirect: 'error', headers
  });
  const pausedRaw = await pausedResponse.text();
  let paused = null; try { paused = JSON.parse(pausedRaw); } catch {}
  if (!pausedResponse.ok || !Array.isArray(paused?.items)) throw new Error('paused_' + pausedResponse.status);

  const candidate = paused.items.find(x => x && x.is_enabled === false && typeof x.id === 'string');
  if (!candidate) throw new Error('no_paused_task');

  const detailResponse = await pacedFetch('/backend-api/automation/' + encodeURIComponent(candidate.id), {
    method: 'GET', credentials: 'include', cache: 'no-store', redirect: 'error', headers
  });
  const detailRaw = await detailResponse.text();
  let detail = null; try { detail = JSON.parse(detailRaw); } catch {}
  if (!detailResponse.ok || !detail) throw new Error('detail_' + detailResponse.status);

  const interesting = {};
  for (const [k, v] of Object.entries(detail)) {
    if (/file|attach|upload|resource|conversation|asset|document|media/i.test(k)) interesting[k] = v;
  }

  const inputs = [...document.querySelectorAll('input[type="file"]')].slice(0, 20).map((el, i) => ({
    index: i,
    accept: el.getAttribute('accept'),
    multiple: !!el.multiple,
    disabled: !!el.disabled,
    name: el.getAttribute('name'),
    aria: el.getAttribute('aria-label'),
    testid: el.getAttribute('data-testid'),
    html: String(el.outerHTML || '').slice(0, 700)
  }));

  const buttons = [...document.querySelectorAll('button')].map((el, i) => ({
    index: i,
    text: String(el.innerText || '').trim().slice(0,120),
    aria: el.getAttribute('aria-label'),
    title: el.getAttribute('title'),
    testid: el.getAttribute('data-testid')
  })).filter(x => /attach|upload|file|add|plus|прикреп|добав|файл/i.test([x.text,x.aria,x.title,x.testid].filter(Boolean).join(' '))).slice(0,40);

  return {
    page_url: location.href,
    task_id: detail.id,
    task_title: detail.title || null,
    task_conversation_id: detail.conversation_id || null,
    task_keys: Object.keys(detail).sort(),
    task_interesting_fields: interesting,
    file_inputs: inputs,
    likely_attachment_buttons: buttons
  };
})()
"@

    $result = Eval -Expression $js -Stage 'phase-a' -Id 1
    Write-Result -Status 'pass' -ExitCode 0 -Data @{
        probe_id = $probeId
        probe_file = $probeFile
        probe_sha256 = $probeHash
        probe_bytes = $probeBytes
        observation = $result
    }
}
catch {
    Write-Result -Status 'fail' -ExitCode 40 -ErrorText $_.Exception.Message -Data @{
        probe_id = $probeId
        probe_file = $probeFile
        probe_sha256 = $probeHash
        probe_bytes = $probeBytes
    }
}
finally {
    try { Close-Session } catch {}
}
