[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$PackageTag = 'direct-bridge-test-6ab0c4d'
$AssetName = 'ChatGptDesktopLocalBridge-DirectBridge.zip'
$ExpectedSha256 = '021f4ef850f88586b3dd98837db04d8b2f77b61c5602f58f405750cc6eefdf73'
$AssetUrl = 'https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/' + $PackageTag + '/' + $AssetName

$ProcessName = 'ChatGptDesktopLocalBridge'
$InstalledAppExe = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$DataRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge'
$LogRoot = Join-Path $DataRoot 'logs'
$WorkRoot = Join-Path $env:TEMP ('direct-bridge-chat-e2e-' + [Guid]::NewGuid().ToString('N'))
$ZipPath = Join-Path $WorkRoot $AssetName
$AppRoot = Join-Path $WorkRoot 'app'
$AppExe = Join-Path $AppRoot 'ChatGptDesktopLocalBridge.exe'
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$WasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket = $null
$Stage = 'init'
$TestStarted = [DateTimeOffset]::UtcNow
$BridgeStatus = ''
$SessionPrefix = ''

function From-Utf8Base64([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Finish {
    param(
        [string]$Status,
        [int]$Code,
        [string]$ErrorText = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        status = $Status
        error = $ErrorText
        exit_code = $Code
        stage = $Stage
        package_tag = $PackageTag
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $directory = Split-Path -Parent $GatewayResultPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $payload | ConvertTo-Json -Depth 24 |
        Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8

    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($payload | ConvertTo-Json -Depth 24 -Compress))
    exit $Code
}

function Stop-App {
    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        }
        catch {}
    }

    Start-Sleep -Seconds 2

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $profileNeedle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $profileNeedle + '*') })) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
        catch {}
    }

    Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds = 45) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $items = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)

        if ($items.Count -gt 0) {
            return $items[0]
        }

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Invoke-Button {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)

    $button = $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $condition)

    if ($null -eq $button) {
        throw "UI button '$Name' was not found."
    }

    $pattern = $null
    if (-not $button.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern)) {
        throw "UI button '$Name' is not invokable."
    }

    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Get-UiTexts {
    param([System.Windows.Automation.AutomationElement]$Root)

    $values = New-Object System.Collections.ArrayList
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)

    foreach ($element in $all) {
        try {
            if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) {
                $name = [string]$element.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$values.Add($name)
                }
            }
        }
        catch {}
    }

    return @($values | Select-Object -Unique)
}

function Wait-Target {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $items = @(Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json') -UseBasicParsing -TimeoutSec 2)
            $target = @($items | Where-Object {
                $_.type -eq 'page' -and
                $_.url -like 'https://chatgpt.com/*' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
            } | Select-Object -First 1)

            if ($target.Count -gt 0) {
                return $target[0]
            }
        }
        catch {}

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Send-Cdp {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 15000
    )

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)

    try {
        [void]$Socket.SendAsync(
            $segment,
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token).GetAwaiter().GetResult()

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

                $message = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json

                if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
                    return $message
                }
            }
            finally {
                $memory.Dispose()
            }
        }
    }
    finally {
        $cts.Dispose()
    }
}

function Eval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Expression
    )

    $response = Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }
    $Id.Value++

    if ($null -ne $response.PSObject.Properties['error']) {
        throw ('CDP error: ' + ($response.error | ConvertTo-Json -Depth 10 -Compress))
    }

    if ($null -ne $response.result.PSObject.Properties['exceptionDetails']) {
        throw ('CDP JavaScript exception: ' + ($response.result.exceptionDetails | ConvertTo-Json -Depth 10 -Compress))
    }

    return $response.result.result.value
}

function Wait-Adapter {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $last = Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
            if ($null -ne $last -and
                [int]$last.version -ge 11 -and
                [bool]$last.webViewAvailable -and
                [bool]$last.composerFound -and
                [bool]$last.nativeInputReady -and
                [bool]$last.sendReceiptAvailable) {
                return $last
            }
        }
        catch {}

        Start-Sleep -Milliseconds 500
    }

    throw ('Adapter v11 did not become ready. Last health: ' + ($last | ConvertTo-Json -Depth 10 -Compress))
}

function Send-ChatText {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Text
    )

    $before = Eval $Socket $Id 'window.__localBridge?.nativeSendReceipt?.(null, 0) ?? null'
    if ($null -eq $before) {
        throw 'Send receipt is unavailable before prompt submit.'
    }

    $baseline = [int]$before.userMessageCount

    $prepare = Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if ($null -eq $prepare -or -not [bool]$prepare.accepted) {
        throw ('Chat preflight rejected: ' + ($prepare | ConvertTo-Json -Depth 10 -Compress))
    }

    [void](Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Input.insertText' -Params @{ text = $Text })
    $Id.Value++

    $expected = $Text | ConvertTo-Json -Compress
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $inserted = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Eval $Socket $Id ('window.__localBridge?.nativeSendState?.(' + $expected + ') ?? null')
        if ($null -ne $state -and [bool]$state.textMatches) {
            $inserted = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not $inserted) {
        throw 'Prompt insert was not verified.'
    }

    $submit = Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if ($null -eq $submit -or -not [bool]$submit.accepted) {
        throw ('Prompt submit rejected: ' + ($submit | ConvertTo-Json -Depth 10 -Compress))
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $receipt = Eval $Socket $Id ('window.__localBridge?.nativeSendReceipt?.(' + $expected + ',' + $baseline + ') ?? null')
        if ($null -ne $receipt -and [bool]$receipt.confirmed) {
            return $receipt
        }
        Start-Sleep -Milliseconds 200
    }

    throw 'Prompt submit began but the exact new user message was not confirmed in the conversation DOM.'
}

function Wait-BridgeReady {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [int]$TimeoutSeconds = 90
    )

    $readyPrefix = From-Utf8Base64 '0JzQvtGB0YIg0LPQvtGC0L7Qsg=='
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastTexts = @()

    while ([DateTime]::UtcNow -lt $deadline) {
        $lastTexts = @(Get-UiTexts $Root)
        $ready = @($lastTexts | Where-Object { $_ -like ($readyPrefix + '*') } | Select-Object -Last 1)
        if ($ready.Count -gt 0) {
            return [string]$ready[0]
        }

        Start-Sleep -Milliseconds 500
    }

    throw ('Bridge READY timeout. UI=' + (@($lastTexts | Select-Object -Last 15) -join ' | '))
}

function Wait-AssistantMarker {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Marker,
        [int]$TimeoutSeconds = 240
    )

    $markerJson = $Marker | ConvertTo-Json -Compress
    $expression = @'
(() => {
  const nodes = Array.from(document.querySelectorAll(
    "[data-markdown-text-style='assistant-message'], [data-message-author-role='assistant']"
  ));
  const texts = nodes.map(n => (n.innerText || n.textContent || "").trim()).filter(Boolean);
  const marker = __MARKER__;
  return {
    found: texts.some(t => t === marker || t.includes(marker)),
    texts: texts.slice(-8)
  };
})()
'@
    $expression = $expression.Replace('__MARKER__', $markerJson)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $last = Eval $Socket $Id $expression
        if ($null -ne $last -and [bool]$last.found) {
            return $last
        }
        Start-Sleep -Milliseconds 500
    }

    throw ('Timed out waiting for final assistant marker. Last assistant texts: ' + ($last | ConvertTo-Json -Depth 10 -Compress))
}

function Find-Audit {
    param(
        [string]$Tool,
        [string]$SessionPrefix,
        [DateTimeOffset]$StartedAfter
    )

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return $null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 4)) {

        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
                $timestamp = [DateTimeOffset]::Parse([string]$record.timestampUtc)

                if ($timestamp -ge $StartedAfter -and
                    [string]$record.session -like ($SessionPrefix + '*') -and
                    [string]$record.tool -eq $Tool) {
                    return $record
                }
            }
            catch {}
        }
    }

    return $null
}

function Has-BridgeResult {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Session,
        [string]$RequestId
    )

    $sessionJson = $Session | ConvertTo-Json -Compress
    $requestJson = $RequestId | ConvertTo-Json -Compress
    return [bool](Eval $Socket $Id ('window.__localBridge?.hasResult?.(' + $sessionJson + ',' + $requestJson + ') ?? false'))
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

try {
    $Stage = 'download-package'
    Invoke-WebRequest -UseBasicParsing -Uri $AssetUrl -OutFile $ZipPath

    $Stage = 'verify-package'
    $hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
    $actualSha256 = ([string]$hash.Hash).ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256) {
        throw "Package SHA256 mismatch: $actualSha256"
    }

    $Stage = 'extract-package'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $AppRoot -Force
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        throw 'Test application executable is missing after package extraction.'
    }

    $Stage = 'start-test-app'
    $port = Get-Random -Minimum 9400 -Maximum 9999
    Stop-App
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe | Out-Null
    $app = Wait-App 45
    if ($null -eq $app) {
        throw 'Test application window did not appear.'
    }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if ($null -eq $root) {
        throw 'UI Automation root unavailable.'
    }

    $Stage = 'connect-chat'
    $target = Wait-Target -Port $port -TimeoutSeconds 60
    if ($null -eq $target) {
        throw 'ChatGPT WebView target unavailable.'
    }

    $Socket = New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $id = 1
    $health = Wait-Adapter -Socket $Socket -Id ([ref]$id) -TimeoutSeconds 60

    $Stage = 'navigate-clean-chat'
    [void](Send-Cdp -Socket $Socket -Id $id -Method 'Page.navigate' -Params @{ url = 'https://chatgpt.com/' } -TimeoutMs 15000)
    $id++
    Start-Sleep -Seconds 5
    $health = Wait-Adapter -Socket $Socket -Id ([ref]$id) -TimeoutSeconds 60

    $Stage = 'initialize-bridge'
    $readyPrefix = From-Utf8Base64 '0JzQvtGB0YIg0LPQvtGC0L7Qsg=='
    $initialTexts = @(Get-UiTexts $root)
    $alreadyReady = @($initialTexts | Where-Object { $_ -like ($readyPrefix + '*') } | Select-Object -Last 1)

    if ($alreadyReady.Count -eq 0) {
        $bridgeButton = From-Utf8Base64 '0JzQvtGB0YI='
        Invoke-Button -Root $root -Name $bridgeButton
    }

    $BridgeStatus = Wait-BridgeReady -Root $root -TimeoutSeconds 100

    if ($BridgeStatus -notmatch '([0-9a-fA-F]{8})') {
        throw ('Could not parse bridge session prefix from status: ' + $BridgeStatus)
    }
    $SessionPrefix = $Matches[1].ToLowerInvariant()

    Start-Sleep -Seconds 5

    $Stage = 'send-two-step-task'
    $prompt = @'
This is a deterministic Local Bridge end-to-end test.
Use only the current direct Local Bridge tools. Do not use local.intent.
Perform exactly these two local steps sequentially, waiting for each LOCAL_BRIDGE_RESULT_V1 before continuing:
1. fs.read_text with args {"path":"C:/Windows/win.ini","max_chars":4096}
2. system.info with args {}
After the second LOCAL_BRIDGE_RESULT_V1, reply with exactly DIRECT_BRIDGE_E2E_PASS and nothing else.
'@

    $sendReceipt = Send-ChatText -Socket $Socket -Id ([ref]$id) -Text $prompt

    $Stage = 'wait-final-marker'
    $marker = Wait-AssistantMarker -Socket $Socket -Id ([ref]$id) -Marker 'DIRECT_BRIDGE_E2E_PASS' -TimeoutSeconds 240

    $Stage = 'verify-audit'
    $fsAudit = Find-Audit -Tool 'fs.read_text' -SessionPrefix $SessionPrefix -StartedAfter $TestStarted
    $systemAudit = Find-Audit -Tool 'system.info' -SessionPrefix $SessionPrefix -StartedAfter $TestStarted
    $intentAudit = Find-Audit -Tool 'local.intent' -SessionPrefix $SessionPrefix -StartedAfter $TestStarted

    if ($null -eq $fsAudit) {
        throw 'No fs.read_text audit record was produced.'
    }
    if ($null -eq $systemAudit) {
        throw 'No system.info audit record was produced.'
    }
    if (-not [bool]$fsAudit.ok) {
        throw ('fs.read_text audit failed: ' + ($fsAudit | ConvertTo-Json -Depth 10 -Compress))
    }
    if (-not [bool]$systemAudit.ok) {
        throw ('system.info audit failed: ' + ($systemAudit | ConvertTo-Json -Depth 10 -Compress))
    }
    if ($null -ne $intentAudit) {
        throw 'local.intent was used during the direct-bridge test.'
    }

    $fsTimestamp = [DateTimeOffset]::Parse([string]$fsAudit.timestampUtc)
    $systemTimestamp = [DateTimeOffset]::Parse([string]$systemAudit.timestampUtc)
    if ($systemTimestamp -lt $fsTimestamp) {
        throw 'system.info executed before fs.read_text; expected sequential two-step order.'
    }

    if ([string]$fsAudit.session -ne [string]$systemAudit.session) {
        throw 'The two direct requests used different bridge sessions.'
    }

    $Stage = 'verify-result-delivery'
    $fsVisible = Has-BridgeResult -Socket $Socket -Id ([ref]$id) -Session ([string]$fsAudit.session) -RequestId ([string]$fsAudit.requestId)
    $systemVisible = Has-BridgeResult -Socket $Socket -Id ([ref]$id) -Session ([string]$systemAudit.session) -RequestId ([string]$systemAudit.requestId)

    if (-not $fsVisible) {
        throw 'fs.read_text LOCAL_BRIDGE_RESULT_V1 is not present in the same conversation.'
    }
    if (-not $systemVisible) {
        throw 'system.info LOCAL_BRIDGE_RESULT_V1 is not present in the same conversation.'
    }

    $Stage = 'pass'
    Finish -Status 'pass' -Code 0 -Extra @{
        package_sha256 = $actualSha256
        adapter_version = [int]$health.version
        initial_prompt_confirmed = [bool]$sendReceipt.confirmed
        bridge_status = $BridgeStatus
        session_prefix = $SessionPrefix
        fs_request_id = [string]$fsAudit.requestId
        system_request_id = [string]$systemAudit.requestId
        fs_result_visible = $fsVisible
        system_result_visible = $systemVisible
        local_intent_used = $false
        final_marker = 'DIRECT_BRIDGE_E2E_PASS'
    }
}
catch {
    $detail = ([string]$_.Exception.Message) +
        ' | line=' + ([string]$_.InvocationInfo.ScriptLineNumber) +
        ' | command=' + ([string]$_.InvocationInfo.Line)

    Finish -Status 'fail' -Code 31 -ErrorText $detail -Extra @{
        bridge_status = $BridgeStatus
        session_prefix = $SessionPrefix
    }
}
finally {
    if ($null -ne $Socket) {
        try { $Socket.Dispose() } catch {}
    }

    try { Stop-App } catch {}

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        $OldBrowserArgs,
        'Process')

    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($WasRunning -and (Test-Path -LiteralPath $InstalledAppExe -PathType Leaf)) {
        try {
            Start-Process -FilePath $InstalledAppExe | Out-Null
        }
        catch {}
    }
}
