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
    $json = $payload | ConvertTo-Json -Depth 20
    $json | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ("PC_GATEWAY_PROJECT_RESULT_JSON=" + ($payload | ConvertTo-Json -Depth 20 -Compress))
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
    if ($items.Count -gt 0) { Start-Sleep -Seconds 2 }
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

    $payload = @{ id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Depth 20 -Compress
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
                $memory.Write($buffer,0,$receive.Count)
            } while (-not $receive.EndOfMessage)

            $text = [Text.Encoding]::UTF8.GetString($memory.ToArray())
            $message = $text | ConvertFrom-Json
            if ($null -ne $message.id -and [int]$message.id -eq $Id) {
                return $message
            }
        }
        finally { $memory.Dispose() }
    }
}

function Get-CdpEvalValue {
    param($Response,[string]$Stage)

    if ($null -eq $Response) { throw ($Stage + ': empty CDP response') }
    if ($null -ne $Response.PSObject.Properties['error']) {
        throw ($Stage + ': CDP error: ' + ($Response.error | ConvertTo-Json -Depth 10 -Compress))
    }
    if ($null -eq $Response.PSObject.Properties['result'] -or
        $null -eq $Response.result.PSObject.Properties['result'] -or
        $null -eq $Response.result.result.PSObject.Properties['value']) {
        throw ($Stage + ': missing result payload: ' + ($Response | ConvertTo-Json -Depth 10 -Compress))
    }
    return $Response.result.result.value
}

$installedExe = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    Write-ProjectResult -Status 'fail' -ExitCode 10 -ErrorText 'Installed bridge executable not found.'
}

$port = Get-Random -Minimum 9400 -Maximum 9999
$oldArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
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
    if ($null -eq $target) { throw 'WebView2 CDP target did not appear.' }

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id = 1

    # Force a clean new-chat surface so the probe is not coupled to whatever thread
    # was visible when the previous runner test stopped.
    [void](Send-CdpCommand -Socket $socket -Id $id -Method 'Page.navigate' -Params @{ url = 'https://chatgpt.com/' })
    $id++
    Start-Sleep -Seconds 3

    $marker = 'LOCAL-BRIDGE-ASSISTANT-DOM-PROBE-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $prompt = 'Reply with exactly this single line and no other text: ' + $marker
    $promptJson = $prompt | ConvertTo-Json -Compress

    $prepareExpression = @'
(() => {
  const c = document.querySelector("#prompt-textarea") ||
            document.querySelector("textarea[data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']") ||
            document.querySelector("div[contenteditable='true'][role='textbox']");
  if (!c) return {ok:false,reason:"composer-not-found"};
  const text=(c.value||c.innerText||c.textContent||"").replace(/\u200B/g,"").trim();
  if (text) return {ok:false,reason:"composer-not-empty",length:text.length};
  c.focus();
  if (!(c instanceof HTMLTextAreaElement) && !(c instanceof HTMLInputElement)) {
    const s=getSelection();
    const r=document.createRange();
    const root=c.querySelector("p")||c;
    r.selectNodeContents(root); r.collapse(false);
    s.removeAllRanges(); s.addRange(r);
  }
  return {ok:true};
})()
'@

    $prepared=$false
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        $r=Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression=$prepareExpression; returnByValue=$true
        }
        $id++
        $v=Get-CdpEvalValue -Response $r -Stage 'prepare'
        if ($null -ne $v -and [bool]$v.ok) { $prepared=$true; break }
        if ($null -ne $v -and [string]$v.reason -eq 'composer-not-empty') {
            throw ('Composer not empty: ' + ($v | ConvertTo-Json -Compress))
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $prepared) {
        $diag=Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression='({href:location.href,readyState:document.readyState,body:(document.body?.innerText||"").slice(0,1500)})'
            returnByValue=$true
        }
        $id++
        $diagValue=Get-CdpEvalValue -Response $diag -Stage 'composer-timeout-diagnostics'
        throw ('Composer did not become ready: ' + ($diagValue | ConvertTo-Json -Compress))
    }

    [void](Send-CdpCommand -Socket $socket -Id $id -Method 'Input.insertText' -Params @{text=$prompt})
    $id++

    $submitExpression=@'
(() => {
  const c=document.querySelector("#prompt-textarea") ||
          document.querySelector("textarea[data-testid='prompt-textarea']") ||
          document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']") ||
          document.querySelector("div[contenteditable='true'][role='textbox']");
  if (!c) return {ok:false,reason:"composer-not-found"};
  const current=(c.value||c.innerText||c.textContent||"").replace(/\u200B/g,"").trim();
  if (current !== __PROMPT_JSON__) return {ok:false,reason:"text-mismatch",current};
  const form=c.closest("form");
  if (!form) return {ok:false,reason:"form-not-found"};
  form.requestSubmit();
  return {ok:true};
})()
'@
    $submitExpression=$submitExpression.Replace('__PROMPT_JSON__',$promptJson)

    $r=Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
        expression=$submitExpression; returnByValue=$true
    }
    $id++
    $v=Get-CdpEvalValue -Response $r -Stage 'submit'
    if (-not [bool]$v.ok) { throw ('Submit failed: '+($v|ConvertTo-Json -Compress)) }

    $markerJson=$marker | ConvertTo-Json -Compress
    $inspectExpression=@'
(() => {
  const marker=__MARKER_JSON__;
  const bodyText=document.body?.innerText||"";
  const legacyA=document.querySelectorAll("[data-message-author-role='assistant']").length;
  const legacyU=document.querySelectorAll("[data-message-author-role='user']").length;

  const selectors=[
    "article",
    "[data-message-id]",
    "[data-message-author-role]",
    "[data-testid*='conversation-turn']",
    "[data-testid*='message']",
    "[data-turn-id]",
    "[data-turn]"
  ];
  const nodes=Array.from(document.querySelectorAll(selectors.join(",")))
    .filter(n => (n.innerText||n.textContent||"").includes(marker))
    .slice(0,20)
    .map(n => ({
      tag:n.tagName,
      id:n.id||null,
      cls:(typeof n.className==="string"?n.className:null),
      attrs:Array.from(n.attributes||[]).reduce((o,a)=>{
        if (a.name.startsWith("data-") || a.name==="role" || a.name==="aria-label") o[a.name]=a.value;
        return o;
      },{}),
      text:(n.innerText||n.textContent||"").trim().slice(0,500),
      html:n.outerHTML.slice(0,2500)
    }));

  const allMarkerNodes=Array.from(document.querySelectorAll("body *"))
    .filter(n => {
      const own=Array.from(n.childNodes||[])
        .filter(x=>x.nodeType===Node.TEXT_NODE)
        .map(x=>x.textContent||"").join("");
      return own.includes(marker);
    })
    .slice(0,20)
    .map(n=>({
      tag:n.tagName,
      id:n.id||null,
      cls:(typeof n.className==="string"?n.className:null),
      attrs:Array.from(n.attributes||[]).reduce((o,a)=>{
        if (a.name.startsWith("data-") || a.name==="role" || a.name==="aria-label") o[a.name]=a.value;
        return o;
      },{}),
      parent:n.parentElement?{
        tag:n.parentElement.tagName,
        id:n.parentElement.id||null,
        cls:(typeof n.parentElement.className==="string"?n.parentElement.className:null),
        attrs:Array.from(n.parentElement.attributes||[]).reduce((o,a)=>{
          if (a.name.startsWith("data-") || a.name==="role" || a.name==="aria-label") o[a.name]=a.value;
          return o;
        },{})
      }:null
    }));

  return {
    markerVisible:bodyText.includes(marker),
    legacyAssistantCount:legacyA,
    legacyUserCount:legacyU,
    candidateNodes:nodes,
    directMarkerNodes:allMarkerNodes
  };
})()
'@
    $inspectExpression=$inspectExpression.Replace('__MARKER_JSON__',$markerJson)

    $final=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(75)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $r=Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
            expression=$inspectExpression; returnByValue=$true
        }
        $id++
        $final=Get-CdpEvalValue -Response $r -Stage 'inspect'
        if ([bool]$final.markerVisible) {
            # Wait a little longer so the exact assistant reply has time to render rather than
            # returning only the user prompt containing the marker.
            Start-Sleep -Seconds 5
            $r=Send-CdpCommand -Socket $socket -Id $id -Method 'Runtime.evaluate' -Params @{
                expression=$inspectExpression; returnByValue=$true
            }
            $id++
            $final=Get-CdpEvalValue -Response $r -Stage 'inspect-final'
            break
        }
    }

    if ($null -eq $final -or -not [bool]$final.markerVisible) {
        throw 'Assistant marker did not become visible within timeout.'
    }

    $summary = [ordered]@{
        marker=$marker
        target_url=[string]$target.url
        legacy_assistant_count=[int]$final.legacyAssistantCount
        legacy_user_count=[int]$final.legacyUserCount
        candidate_nodes=$final.candidateNodes
        direct_marker_nodes=$final.directMarkerNodes
    }
    # Deliberately surface the diagnostic payload through the gateway error channel.
    # This probe is evidence collection, not a product pass/fail gate.
    Write-ProjectResult -Status 'diagnostic' -ExitCode 42 -ErrorText ($summary | ConvertTo-Json -Depth 20 -Compress)
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}
finally {
    if ($null -ne $socket) { try { $socket.Dispose() } catch {} }
    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldArgs,'Process')
    if ($wasRunning -and (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        try { Start-Process -FilePath $installedExe | Out-Null } catch {}
    }
}
