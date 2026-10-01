[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

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
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $payload | ConvertTo-Json -Depth 12
    $json | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ("PC_GATEWAY_PROJECT_RESULT_JSON=" + ($payload | ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

function Stop-BridgeApp {
    $items = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)
    foreach ($p in $items) {
        try { [void]$p.CloseMainWindow() } catch {}
    }
    Start-Sleep -Seconds 2
    $items = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)
    foreach ($p in $items) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Seconds 1
}

function Stop-BridgeWebViewProcesses {
    $profileNeedle = 'ChatGptDesktopLocalBridge\WebView2'
    $items = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $profileNeedle + '*') })

    foreach ($item in $items) {
        try { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop } catch {}
    }

    if ($items.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}


function Wait-ForCdpTarget {
    param([int]$Port, [int]$TimeoutSeconds = 45)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/json") -UseBasicParsing -TimeoutSec 2)
            $target = @($targets | Where-Object {
                $_.type -eq 'page' -and
                $_.url -like 'https://chatgpt.com/*' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
            } | Select-Object -First 1)

            if ($target.Count -gt 0) { return $target[0] }
        } catch {}

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Send-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 20 -Compress

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    [void]($Socket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult())

    while ($true) {
        $memory = New-Object IO.MemoryStream
        try {
            do {
                $buffer = New-Object byte[] 65536
                $bufferSegment = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
                $receive = $Socket.ReceiveAsync(
                    $bufferSegment,
                    [Threading.CancellationToken]::None).GetAwaiter().GetResult()

                if ($receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw 'CDP websocket closed.'
                }

                $memory.Write($buffer, 0, $receive.Count)
            } while (-not $receive.EndOfMessage)

            $text = [Text.Encoding]::UTF8.GetString($memory.ToArray())
            $message = $text | ConvertFrom-Json
            if ($null -ne $message.id -and [int]$message.id -eq $Id) {
                return $message
            }
        }
        finally {
            $memory.Dispose()
        }
    }
}

function Get-CdpEvalValue {
    param(
        $Response,
        [string]$Stage
    )

    if ($null -eq $Response) {
        throw ($Stage + ': empty CDP response')
    }

    if ($null -ne $Response.PSObject.Properties['error']) {
        throw ($Stage + ': CDP error: ' + ($Response.error | ConvertTo-Json -Depth 10 -Compress))
    }

    if ($null -eq $Response.PSObject.Properties['result']) {
        throw ($Stage + ': missing outer result: ' + ($Response | ConvertTo-Json -Depth 10 -Compress))
    }

    $outer = $Response.result
    if ($null -eq $outer.PSObject.Properties['result']) {
        throw ($Stage + ': missing evaluation result: ' + ($Response | ConvertTo-Json -Depth 10 -Compress))
    }

    $inner = $outer.result
    if ($null -eq $inner.PSObject.Properties['value']) {
        throw ($Stage + ': missing by-value payload: ' + ($Response | ConvertTo-Json -Depth 10 -Compress))
    }

    return $inner.value
}


$installedExe = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    Write-ProjectResult -Status 'fail' -ExitCode 10 -ErrorText 'Installed bridge executable not found.'
}

$port = Get-Random -Minimum 9400 -Maximum 9999
$oldArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$wasRunning = @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue).Count -gt 0
$socket = $null

try {
    Stop-BridgeApp
    Stop-BridgeWebViewProcesses

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ("--remote-debugging-port=" + $port + " --remote-allow-origins=*"),
        'Process')

    Start-Process -FilePath $installedExe | Out-Null
    $target = Wait-ForCdpTarget -Port $port -TimeoutSeconds 45
    if ($null -eq $target) {
        throw 'WebView2 CDP target did not appear.'
    }

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $id = 1
    $focusExpression = @'
(() => {
  const selectors = [
    "#prompt-textarea",
    "textarea[data-testid='prompt-textarea']",
    "div[contenteditable='true'][data-testid='prompt-textarea']",
    "div[contenteditable='true'][role='textbox']"
  ];
  let composer = null;
  for (const selector of selectors) {
    composer = document.querySelector(selector);
    if (composer) break;
  }
  if (!composer) return { ok:false, reason:"composer-not-found" };

  const current = (composer.value || composer.innerText || composer.textContent || "").replace(/\u200B/g, "").trim();
  if (current) return { ok:false, reason:"composer-not-empty", length:current.length };

  composer.focus();
  if (!(composer instanceof HTMLTextAreaElement) && !(composer instanceof HTMLInputElement)) {
    const selection = getSelection();
    const range = document.createRange();
    const root = composer.querySelector("p") || composer;
    range.selectNodeContents(root);
    range.collapse(false);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  return {
    ok:true,
    beforeUsers:document.querySelectorAll("[data-message-author-role='user']").length
  };
})()
'@

    $focusValue = $null
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(60)

    while ([DateTime]::UtcNow -lt $focusDeadline) {
        $focus = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression = $focusExpression
            returnByValue = $true
            awaitPromise = $true
        }
        $id++

        $focusValue = Get-CdpEvalValue -Response $focus -Stage 'focus'
        if ($null -ne $focusValue -and [bool]$focusValue.ok) {
            break
        }

        if ($null -ne $focusValue -and [string]$focusValue.reason -eq 'composer-not-empty') {
            throw ('Composer preflight failed: ' + ($focusValue | ConvertTo-Json -Compress))
        }

        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $focusValue -or -not [bool]$focusValue.ok) {
        throw ('Composer did not become ready: ' + ($focusValue | ConvertTo-Json -Compress))
    }

    $beforeUsers = [int]$focusValue.beforeUsers
    $marker = 'LOCAL-BRIDGE-NATIVE-INPUT-PROBE-' + [Guid]::NewGuid().ToString('N').Substring(0,8)

    [void](Send-CdpCommand -Socket $socket -Id $id -Method 'Input.insertText' -Params @{ text = $marker })
    $id++
    Start-Sleep -Milliseconds 700

    $inspectExpression = @'
(() => {
  const c = document.querySelector("#prompt-textarea") ||
            document.querySelector("textarea[data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][role='textbox']");
  const text = c ? (c.value || c.innerText || c.textContent || "").replace(/\u200B/g, "") : "";
  const form = c ? c.closest("form") : null;
  const buttons = form ? Array.from(form.querySelectorAll("button")).slice(0, 24).map((b, i) => ({
    i,
    type:b.getAttribute("type"),
    testid:b.getAttribute("data-testid"),
    aria:b.getAttribute("aria-label"),
    title:b.getAttribute("title"),
    disabled:Boolean(b.disabled),
    text:(b.innerText || b.textContent || "").trim().slice(0, 120),
    html:b.outerHTML.slice(0, 700)
  })) : [];
  const send = document.querySelector("button[data-testid='send-button']") ||
               document.querySelector("button[aria-label='Send prompt']") ||
               document.querySelector("button[aria-label='Send message']") ||
               document.querySelector("button[aria-label*='Send']");
  return {
    text,
    sendFound:Boolean(send),
    sendDisabled:send ? Boolean(send.disabled) : null,
    users:document.querySelectorAll("[data-message-author-role='user']").length,
    markerInDocument:document.body.textContent.includes(__MARKER_JSON__),
    formFound:Boolean(form),
    formButtons:buttons,
    formHtml:form ? form.outerHTML.slice(0, 7000) : null
  };
})()
'@
    $markerJson = $marker | ConvertTo-Json -Compress
    $inspectExpression = $inspectExpression.Replace('__MARKER_JSON__', $markerJson)

    $inspect = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
        expression = $inspectExpression
        returnByValue = $true
    }
    $id++

    $state = Get-CdpEvalValue -Response $inspect -Stage 'inspect-after-insert'
    if ($null -eq $state -or [string]$state.text -ne $marker) {
        throw ('Native insert was not accepted by composer: ' + ($state | ConvertTo-Json -Depth 12 -Compress))
    }

    $submitExpression = @'
(() => {
  const c = document.querySelector("#prompt-textarea") ||
            document.querySelector("textarea[data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][role='textbox']");
  const form = c ? c.closest("form") : null;
  if (!form) return {ok:false, reason:"form-not-found"};
  try {
    form.requestSubmit();
    return {ok:true, strategy:"requestSubmit"};
  } catch (e) {
    return {ok:false, reason:String(e)};
  }
})()
'@

    $submit = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
        expression = $submitExpression
        returnByValue = $true
    }
    $id++
    $submitValue = Get-CdpEvalValue -Response $submit -Stage 'request-submit'

    $submitted = $false
    $finalState = $state
    $submitStrategy = 'requestSubmit'
    $deadline = [DateTime]::UtcNow.AddSeconds(6)

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $probe = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression = $inspectExpression
            returnByValue = $true
        }
        $id++

        $finalState = Get-CdpEvalValue -Response $probe -Stage 'inspect-after-request-submit'
        $textNow = [string]$finalState.text
        $usersNow = [int]$finalState.users

        if ([bool]$finalState.markerInDocument -and [string]::IsNullOrWhiteSpace($textNow)) {
            $submitted = $true
            break
        }
    }

    if (-not $submitted -and [string]$finalState.text -eq $marker) {
        $clickExpression = @'
(() => {
  const c = document.querySelector("#prompt-textarea") ||
            document.querySelector("textarea[data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][role='textbox']");
  const form = c ? c.closest("form") : null;
  if (!form) return {ok:false, reason:"form-not-found"};

  const buttons = Array.from(form.querySelectorAll("button"));
  const candidate =
    form.querySelector("button[type='submit']") ||
    buttons.find(b => (b.getAttribute("data-testid") || "").toLowerCase().includes("send")) ||
    buttons.find(b => (b.getAttribute("aria-label") || "").toLowerCase().includes("send")) ||
    buttons.slice().reverse().find(b => !b.disabled && b.offsetParent !== null);

  if (!candidate) return {ok:false, reason:"candidate-button-not-found"};
  candidate.click();
  return {
    ok:true,
    strategy:"button-click",
    type:candidate.getAttribute("type"),
    testid:candidate.getAttribute("data-testid"),
    aria:candidate.getAttribute("aria-label")
  };
})()
'@

        $click = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression = $clickExpression
            returnByValue = $true
        }
        $id++
        $clickValue = Get-CdpEvalValue -Response $click -Stage 'button-click'
        $submitStrategy = 'button-click'

        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
            $probe = Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
                expression = $inspectExpression
                returnByValue = $true
            }
            $id++

            $finalState = Get-CdpEvalValue -Response $probe -Stage 'inspect-after-button-click'
            $textNow = [string]$finalState.text
            $usersNow = [int]$finalState.users

            if ($usersNow -gt $beforeUsers -and [string]::IsNullOrWhiteSpace($textNow)) {
                $submitted = $true
                break
            }
        }
    }

    if (-not $submitted) {
        throw ('Native insert accepted but submit was not confirmed. requestSubmit=' +
            ($submitValue | ConvertTo-Json -Depth 8 -Compress) +
            ' state=' + ($finalState | ConvertTo-Json -Depth 12 -Compress))
    }

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        target_url = [string]$target.url
        marker = $marker
        insert_accepted = $true
        send_button_after_insert = [bool]$state.sendFound
        form_found = [bool]$state.formFound
        form_buttons = $state.formButtons
        submit_strategy = $submitStrategy
        submit_confirmed = $true
        users_before = $beforeUsers
        users_after = [int]$finalState.users
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}
finally {
    if ($null -ne $socket) {
        try {
            $socket.Dispose()
        } catch {}
    }

    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', $oldArgs, 'Process')

    if ($wasRunning -and (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        try { Start-Process -FilePath $installedExe | Out-Null } catch {}
    }
}
