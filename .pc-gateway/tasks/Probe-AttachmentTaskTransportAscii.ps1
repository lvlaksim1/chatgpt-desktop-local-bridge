[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$GapSeconds = 5
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ProcessName = 'ChatGptDesktopLocalBridge'
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$Socket = $null

function Write-ProjectResult {
    param([string]$Status, [int]$Code, [string]$ErrorText = '', [hashtable]$Extra = @{})
    $o = [ordered]@{ status = $Status; exit_code = $Code; error = $ErrorText; network_min_gap_seconds = $GapSeconds }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $o | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $Code
}

function Stop-BridgeApp {
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds = 45) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
        if ($p.Count -gt 0) { return $p[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-Target([int]$Port, [int]$TimeoutSeconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json') -UseBasicParsing -TimeoutSec 2)
            $t = @($targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl } | Select-Object -First 1)
            if ($t.Count -gt 0) { return $t[0] }
        } catch {}
        Start-Sleep -Seconds $GapSeconds
    }
    return $null
}

function Send-Cdp {
    param([int]$Id, [string]$Method, [hashtable]$Params)
    $json = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(180000)
    try {
        [void]($script:Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult())
        while ($true) {
            $mem = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $seg = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
                    $rx = $script:Socket.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
                    if ($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'cdp_closed' }
                    $mem.Write($buffer, 0, $rx.Count)
                } while (-not $rx.EndOfMessage)
                $m = ([Text.Encoding]::UTF8.GetString($mem.ToArray()) | ConvertFrom-Json)
                if ($null -ne $m.PSObject.Properties['id'] -and [int]$m.id -eq $Id) { return $m }
            } finally { $mem.Dispose() }
        }
    } finally { $cts.Dispose() }
}

function Eval-Js([string]$Expression) {
    $r = Send-Cdp -Id 1 -Method 'Runtime.evaluate' -Params @{ expression = $Expression; returnByValue = $true; awaitPromise = $true }
    if ($null -ne $r.PSObject.Properties['error']) { throw ('cdp_error:' + ($r.error | ConvertTo-Json -Compress)) }
    if ($null -ne $r.result.PSObject.Properties['exceptionDetails']) { throw ('js_exception:' + ($r.result.exceptionDetails | ConvertTo-Json -Depth 5 -Compress)) }
    return $r.result.result.value
}

function Open-Session {
    Stop-BridgeApp
    $port = Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'), 'Process')
    Start-Process -FilePath $AppExe | Out-Null
    if ($null -eq (Wait-App)) { throw 'app_window_missing' }
    $target = Wait-Target -Port $port
    if ($null -eq $target) { throw 'cdp_target_missing' }
    Start-Sleep -Seconds 10
    $s = New-Object Net.WebSockets.ClientWebSocket
    $s.ConnectAsync([Uri][string]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $script:Socket = $s
}

function Close-Session {
    if ($null -ne $script:Socket) { try { $script:Socket.Dispose() } catch {}; $script:Socket = $null }
    try { Stop-BridgeApp } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', $OldBrowserArgs, 'Process')
}

if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
    Write-ProjectResult -Status 'fail' -Code 32 -ErrorText 'installed_app_missing'
}

$ProbeId = 'attach-' + [Guid]::NewGuid().ToString('N').Substring(0, 16)
$ProbeFile = Join-Path $env:TEMP ($ProbeId + '.json')
$Russian = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0J/RgNC+0LLQtdGA0LrQsCDQutC40YDQuNC70LvQuNGG0Ys6INC80L7RgdGCINC/0L7Qu9GD0YfQsNC10YIg0YTQsNC50Lsg0LHQtdC3INC40YHQutCw0LbQtdC90LjQuQ=='))
$ProbeObject = [ordered]@{ schema = 'local-bridge-attachment-probe-v1'; probe_id = $ProbeId; russian = $Russian; marker = 'FILE-ATTACHMENT-PROBE' }
$ProbeText = $ProbeObject | ConvertTo-Json -Compress
[IO.File]::WriteAllText($ProbeFile, $ProbeText, [Text.UTF8Encoding]::new($false))
$ProbeHash = (Get-FileHash -LiteralPath $ProbeFile -Algorithm SHA256).Hash.ToLowerInvariant()
$ProbeBytes = (Get-Item -LiteralPath $ProbeFile).Length

try {
    Open-Session
    $js = @'
(async () => {
  const GAP = 5000;
  let last = 0;
  const delay = ms => new Promise(r => setTimeout(r, ms));
  async function pfetch(path, init) {
    const wait = Math.max(0, last + GAP - Date.now());
    if (wait) await delay(wait);
    try { return await fetch(path, init); } finally { last = Date.now(); }
  }
  const ar = await pfetch('/api/auth/session', { credentials:'include', cache:'no-store', redirect:'error', headers:{accept:'application/json'} });
  if (!ar.ok) throw new Error('auth_' + ar.status);
  const sess = await ar.json();
  const token = sess && sess.accessToken ? sess.accessToken : '';
  const accountId = sess && sess.account && sess.account.id ? sess.account.id : '';
  if (!token) throw new Error('missing_token');
  const h = { accept:'application/json, text/plain, */*', authorization:'Bearer ' + token };
  if (accountId) h['chatgpt-account-id'] = accountId;

  const pr = await pfetch('/backend-api/automations?filter=paused', { method:'GET', credentials:'include', cache:'no-store', redirect:'error', headers:h });
  const pt = await pr.text();
  let pj = null; try { pj = JSON.parse(pt); } catch (e) {}
  if (!pr.ok || !pj || !Array.isArray(pj.items)) throw new Error('paused_' + pr.status);
  const row = pj.items.find(x => x && x.is_enabled === false && typeof x.id === 'string');
  if (!row) throw new Error('no_paused_task');

  const dr = await pfetch('/backend-api/automation/' + encodeURIComponent(row.id), { method:'GET', credentials:'include', cache:'no-store', redirect:'error', headers:h });
  const dt = await dr.text();
  let detail = null; try { detail = JSON.parse(dt); } catch (e) {}
  if (!dr.ok || !detail) throw new Error('detail_' + dr.status);

  const interesting = {};
  for (const k of Object.keys(detail)) {
    if (/file|attach|upload|resource|conversation|asset|document|media/i.test(k)) interesting[k] = detail[k];
  }
  const inputs = Array.from(document.querySelectorAll('input[type="file"]')).slice(0,20).map((el,i) => ({
    index:i, accept:el.getAttribute('accept'), multiple:!!el.multiple, disabled:!!el.disabled,
    name:el.getAttribute('name'), aria:el.getAttribute('aria-label'), testid:el.getAttribute('data-testid')
  }));
  const buttons = Array.from(document.querySelectorAll('button')).map((el,i) => ({
    index:i, text:String(el.innerText||'').trim().slice(0,120), aria:el.getAttribute('aria-label'),
    title:el.getAttribute('title'), testid:el.getAttribute('data-testid')
  })).filter(x => /attach|upload|file|add|plus/i.test([x.text,x.aria,x.title,x.testid].filter(Boolean).join(' '))).slice(0,40);
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
'@
    $Observation = Eval-Js -Expression $js
    Write-ProjectResult -Status 'pass' -Code 0 -Extra @{
        probe_id = $ProbeId
        probe_file = $ProbeFile
        probe_sha256 = $ProbeHash
        probe_bytes = $ProbeBytes
        observation = $Observation
    }
}
catch {
    Write-ProjectResult -Status 'fail' -Code 40 -ErrorText $_.Exception.Message -Extra @{
        probe_id = $ProbeId
        probe_file = $ProbeFile
        probe_sha256 = $ProbeHash
        probe_bytes = $ProbeBytes
    }
}
finally {
    try { Close-Session } catch {}
}
