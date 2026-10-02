[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$BaseTag = 'dev-85c714c'
$BaseCommit = '85c714c9b46df2c8ea5329b2d265953d9735ee3f'
$TargetTag = 'dev-31e823e'
$TargetCommit = '31e823ef7854a18bb2ad10e94ec71c51814628eb'
$UpdateAsset = 'ChatGptDesktopLocalBridge-Update-from-dev-85c714c.exe'
$ExpectedUpdateSha256 = '017c9494c31feec8bb42f0078fcc2b376e9c352cfcd6df3dfb6e50faa3e174b5'
$RequestId = 'req-m3-live-31e823e'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$LogRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$LedgerRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\state\requests'
$ProcessName = 'ChatGptDesktopLocalBridge'
$TempRoot = Join-Path $env:TEMP ('bridge-m3-live-' + [Guid]::NewGuid().ToString('N'))
$UpdateExe = Join-Path $TempRoot $UpdateAsset
$UpdateLog = Join-Path $TempRoot 'update.log'
$OldSkipRestart = [Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','Process')
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket = $null
$Stage = 'start'
$BridgeStatus = ''
$ConversationUri = ''
$LedgerRecord = $null
$TestStarted = [DateTimeOffset]::UtcNow

function Finish {
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
        stage = $Stage
        base_tag = $BaseTag
        target_tag = $TargetTag
        target_commit = $TargetCommit
        request_id = $RequestId
    }
    foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($payload | ConvertTo-Json -Depth 20 -Compress))
    exit $ExitCode
}

function Stop-App {
    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
        } catch {}
    }

    Start-Sleep -Seconds 2
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $needle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $needle + '*') })) {
        try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop } catch {}
    }

    Start-Sleep -Seconds 1
}

function Wait-App {
    param([int]$TimeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1)

        if ($process.Count -gt 0) { return $process[0] }
        Start-Sleep -Milliseconds 250
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
    $button = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -eq $button) { throw "UI button '$Name' was not found." }

    $pattern = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
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
                if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$values.Add($name) }
            }
        } catch {}
    }

    return @($values | Select-Object -Unique)
}

function Get-Diagnostics {
    param([System.Windows.Automation.AutomationElement]$Root)

    Invoke-Button -Root $Root -Name 'Diagnostics'
    Start-Sleep -Milliseconds 700

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        'Local Bridge diagnostics')
    $dialog = $desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)

    if ($null -eq $dialog) { return 'diagnostics-dialog-not-found' }

    $parts = New-Object System.Collections.ArrayList
    $all = $dialog.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)

    foreach ($element in $all) {
        try {
            $name = [string]$element.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$parts.Add($name) }
        } catch {}
    }

    try {
        $okCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            'OK')
        $okButton = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCondition)
        if ($null -ne $okButton) {
            $pattern = $null
            if ($okButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
            }
        }
    } catch {}

    return (@($parts | Select-Object -Unique) -join ' || ')
}

function Wait-Target {
    param([int]$Port, [int]$TimeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $items = @(Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json') -UseBasicParsing -TimeoutSec 2)
            $target = @($items |
                Where-Object {
                    $_.type -eq 'page' -and
                    $_.url -like 'https://chatgpt.com/*' -and
                    $_.webSocketDebuggerUrl
                } |
                Select-Object -First 1)

            if ($target.Count -gt 0) { return $target[0] }
        } catch {}

        Start-Sleep -Milliseconds 250
    }

    return $null
}

function Send-Cdp {
    param(
        $Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $payload = @{ id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(10000)

    try {
        [void]$Socket.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token).GetAwaiter().GetResult()

        while ($true) {
            $stream = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $rxSegment = New-Object ArraySegment[byte] -ArgumentList (,$buffer)
                    $rx = $Socket.ReceiveAsync($rxSegment, $cts.Token).GetAwaiter().GetResult()
                    if ($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'CDP socket closed.'
                    }
                    $stream.Write($buffer, 0, $rx.Count)
                } while (-not $rx.EndOfMessage)

                $message = ([Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json)
                if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
                    return $message
                }
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $cts.Dispose()
    }
}

function Eval {
    param($Socket, [ref]$Id, [string]$Expression)

    $response = Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }
    $Id.Value++

    if ($null -ne $response.PSObject.Properties['error']) {
        throw ('CDP error: ' + ($response.error | ConvertTo-Json -Compress))
    }

    return $response.result.result.value
}

function Send-ChatText {
    param($Socket, [ref]$Id, [string]$Text)

    $prepare = Eval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if ($null -eq $prepare -or -not [bool]$prepare.accepted) {
        throw ('Chat preflight rejected: ' + ($prepare | ConvertTo-Json -Compress))
    }

    [void](Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Input.insertText' -Params @{ text=$Text })
    $Id.Value++

    $expected = $Text | ConvertTo-Json -Compress
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    $inserted = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Eval -Socket $Socket -Id $Id -Expression ('window.__localBridge?.nativeSendState?.(' + $expected + ') ?? null')
        if ($null -ne $state -and [bool]$state.textMatches) {
            $inserted = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not $inserted) { throw 'Prompt insert was not verified.' }

    $submit = Eval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if ($null -eq $submit -or -not [bool]$submit.accepted) {
        throw ('Prompt submit rejected: ' + ($submit | ConvertTo-Json -Compress))
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Eval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.nativeSendState?.() ?? null'
        if ($null -ne $state -and [bool]$state.composerEmpty) { return }
        Start-Sleep -Milliseconds 100
    }

    throw 'Prompt submit was not confirmed.'
}

function Find-FsReadAudit {
    param(
        [string]$RequestIdValue,
        [DateTimeOffset]$StartedAfter
    )

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return $null }

    foreach ($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 3)) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $record = $line | ConvertFrom-Json
                $timestamp = [DateTimeOffset]::Parse([string]$record.timestampUtc)
                if ($timestamp -lt $StartedAfter) { continue }

                if ([string]$record.requestId -eq $RequestIdValue -and
                    [string]$record.tool -eq 'fs.read_text') {
                    return $record
                }
            } catch {}
        }
    }

    return $null
}

function Normalize-ConversationUri {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $uri = [Uri]$Value
    $path = $uri.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }

    $builder = New-Object UriBuilder $uri
    $builder.Query = ''
    $builder.Fragment = ''
    $builder.Path = $path

    return $builder.Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')
}

function Find-LedgerRecord {
    param([string]$RequestIdValue)

    if (-not (Test-Path -LiteralPath $LedgerRoot -PathType Container)) { return $null }

    foreach ($file in @(Get-ChildItem -LiteralPath $LedgerRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$record.requestId -eq $RequestIdValue) {
                return [pscustomobject]@{
                    file = $file.FullName
                    record = $record
                }
            }
        } catch {}
    }

    return $null
}

try {
    if ($ExpectedUpdateSha256 -like '__*') {
        throw 'Release updater SHA-256 has not been sealed into this test script.'
    }

    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        throw 'Installed application executable is missing.'
    }
    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) {
        throw 'Installed release-info.json is missing.'
    }

    $Stage = 'verify-installed-base'
    $before = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $alreadyCurrent =
        [string]$before.tag -eq $TargetTag -and
        [string]$before.commit -eq $TargetCommit

    if (-not $alreadyCurrent -and
        ([string]$before.tag -ne $BaseTag -or [string]$before.commit -ne $BaseCommit)) {
        throw "Installed base mismatch: '$($before.tag)' '$($before.commit)'."
    }

    if (-not $alreadyCurrent) {
        $Stage = 'download-update'
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
        $url = 'https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/' +
            $TargetTag + '/' + $UpdateAsset

        $client = New-Object Net.WebClient
        try { $client.DownloadFile($url, $UpdateExe) } finally { $client.Dispose() }

        $actualSha = (Get-FileHash -LiteralPath $UpdateExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $ExpectedUpdateSha256) {
            throw "Updater hash mismatch: $actualSha"
        }

        $Stage = 'apply-update'
        Stop-App
        [Environment]::SetEnvironmentVariable(
            'CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',
            '1',
            'Process')

        $updateProcess = Start-Process -FilePath $UpdateExe -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            ('/LOG=' + $UpdateLog)
        ) -PassThru

        if (-not $updateProcess.WaitForExit(120000)) {
            try { Stop-Process -Id $updateProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
            throw 'Updater timed out after 120 seconds.'
        }

        $updateProcess.Refresh()
        if ($updateProcess.ExitCode -ne 0) {
            $tail = ''
            if (Test-Path -LiteralPath $UpdateLog) {
                $tail = @(Get-Content -LiteralPath $UpdateLog -Tail 80) -join [Environment]::NewLine
            }
            throw "Updater failed with exit code $($updateProcess.ExitCode). $tail"
        }
    }

    $Stage = 'verify-target-release'
    $after = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$after.tag -ne $TargetTag -or [string]$after.commit -ne $TargetCommit) {
        throw "Target release marker mismatch: '$($after.tag)' '$($after.commit)'."
    }

    $port = Get-Random -Minimum 9400 -Maximum 9999
    $Stage = 'start-target-app'
    Stop-App
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe | Out-Null
    $process = Wait-App -TimeoutSeconds 30
    if ($null -eq $process) { throw 'Application window did not appear.' }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    if ($null -eq $root) { throw 'UI Automation root unavailable.' }

    $Stage = 'wait-adapter-v8'
    $diag = ''
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(30)

    while ([DateTime]::UtcNow -lt $deadline) {
        $diag = Get-Diagnostics -Root $root
        if ($diag -match '"version"\s*:\s*8' -and
            $diag -match '"composerFound"\s*:\s*true' -and
            $diag -match '"nativeInputReady"\s*:\s*true') {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $ready) { throw ('Adapter/composer not ready: ' + $diag) }

    $Stage = 'connect-cdp'
    $target = Wait-Target -Port $port -TimeoutSeconds 30
    if ($null -eq $target) { throw 'CDP target unavailable.' }

    $Socket = New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $id = 1

    $Stage = 'initialize-bridge'
    Invoke-Button -Root $root -Name 'Initialize Bridge'

    $deadline = [DateTime]::UtcNow.AddSeconds(70)
    while ([DateTime]::UtcNow -lt $deadline) {
        $texts = @(Get-UiTexts -Root $root)
        $ok = @($texts | Where-Object { $_ -like 'Bridge ready. Session*' } | Select-Object -First 1)

        if ($ok.Count -gt 0) {
            $BridgeStatus = [string]$ok[0]
            break
        }

        $fail = @($texts | Where-Object {
            $_ -like 'Chat send failed:*' -or
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*'
        } | Select-Object -First 1)

        if ($fail.Count -gt 0) { throw ([string]$fail[0]) }
        Start-Sleep -Milliseconds 250
    }

    if ([string]::IsNullOrWhiteSpace($BridgeStatus)) { throw 'Bridge READY timeout.' }

    $ConversationUri = [string](Eval -Socket $Socket -Id ([ref]$id) -Expression 'location.href')
    $normalizedConversation = Normalize-ConversationUri -Value $ConversationUri
    if ([string]::IsNullOrWhiteSpace($normalizedConversation) -or
        $normalizedConversation -notlike 'https://chatgpt.com/c/*') {
        throw "Bridge did not settle on a durable ChatGPT conversation URI: '$ConversationUri'."
    }

    $Stage = 'send-fs-read-request'
    $prompt =
        'Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose. ' +
        'Use id ' + $RequestId + '. Use tool fs.read_text with args.path C:/Windows/win.ini and args.max_chars 4096. ' +
        'In the JSON request, keep that path exactly with forward slashes. Wait for LOCAL_BRIDGE_RESULT_V1 before any further response.'

    Send-ChatText -Socket $Socket -Id ([ref]$id) -Text $prompt

    $Stage = 'wait-local-execution'
    $audit = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(75)

    while ([DateTime]::UtcNow -lt $deadline) {
        $audit = Find-FsReadAudit -RequestIdValue $RequestId -StartedAfter $TestStarted
        if ($null -ne $audit) { break }
        Start-Sleep -Milliseconds 250
    }

    if ($null -eq $audit) {
        $assistantDiag = Eval -Socket $Socket -Id ([ref]$id) -Expression @'
(() => {
  const nodes = Array.from(document.querySelectorAll(
    "[data-markdown-text-style='assistant-message'], [data-message-author-role='assistant']"));
  return nodes.slice(-6).map(node =>
    (node.innerText || node.textContent || "").trim().slice(0,2400));
})()
'@
        throw ('No fs.read_text audit record appeared. ASSISTANT=' +
            ($assistantDiag | ConvertTo-Json -Depth 6 -Compress))
    }

    if (-not [bool]$audit.ok) {
        throw ('fs.read_text audit failed: ' + ($audit | ConvertTo-Json -Compress))
    }

    $Stage = 'verify-durable-ledger'
    $ledgerMatch = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)

    while ([DateTime]::UtcNow -lt $deadline) {
        $ledgerMatch = Find-LedgerRecord -RequestIdValue $RequestId

        if ($null -ne $ledgerMatch) {
            $record = $ledgerMatch.record
            if ([string]$record.executionState -eq 'completed' -and
                [string]$record.deliveryState -eq 'delivered') {
                break
            }
        }

        Start-Sleep -Milliseconds 250
    }

    if ($null -eq $ledgerMatch) { throw 'Durable ledger record was not found.' }
    $LedgerRecord = $ledgerMatch.record

    if ([string]$LedgerRecord.executionState -ne 'completed') {
        throw "Unexpected execution state: '$($LedgerRecord.executionState)'."
    }
    if ([string]$LedgerRecord.deliveryState -ne 'delivered') {
        throw "Unexpected delivery state: '$($LedgerRecord.deliveryState)'."
    }
    if ($null -ne $LedgerRecord.resultEnvelopeJson) {
        throw 'Delivered durable record retained resultEnvelopeJson.'
    }
    if ([string]$LedgerRecord.conversationUri -ne $normalizedConversation) {
        throw "Conversation binding mismatch: ledger='$($LedgerRecord.conversationUri)' browser='$normalizedConversation'."
    }

    $Stage = 'pass'
    Finish -Status 'pass' -ExitCode 0 -Extra @{
        updated_from = [string]$before.tag
        installed_release = [string]$after.tag
        bridge_status = $BridgeStatus
        conversation_uri = $normalizedConversation
        fs_read_audit_ok = [bool]$audit.ok
        fs_read_elapsed_ms = [long]$audit.elapsedMs
        ledger_execution_state = [string]$LedgerRecord.executionState
        ledger_delivery_state = [string]$LedgerRecord.deliveryState
        delivered_payload_retired = ($null -eq $LedgerRecord.resultEnvelopeJson)
        ledger_file = [string]$ledgerMatch.file
    }
}
catch {
    Finish -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        bridge_status = $BridgeStatus
        conversation_uri = $ConversationUri
    }
}
finally {
    if ($null -ne $Socket) {
        try { $Socket.Dispose() } catch {}
    }

    try { Stop-App } catch {}

    [Environment]::SetEnvironmentVariable(
        'CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',
        $OldSkipRestart,
        'Process')
    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        $OldBrowserArgs,
        'Process')

    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        try { Start-Process -FilePath $AppExe | Out-Null } catch {}
    }
}
