[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$TargetTag = 'dev-65d8ecc'
$TargetCommit = '65d8ecc1980277d07b27a07c70ceb6b322e06c51'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$DataRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge'
$LogRoot = Join-Path $DataRoot 'logs'
$ProcessName = 'ChatGptDesktopLocalBridge'
$TempRoot = Join-Path $env:TEMP ('bridge-m1-e2e-' + [Guid]::NewGuid().ToString('N'))
$UpdaterPath = Join-Path $TempRoot 'update.exe'
$UpdaterLog = Join-Path $TempRoot 'update-inno.log'
$socket = $null
$oldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$oldSkipRestart = [Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART', 'Process')
$leaveAppRunning = $true

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
        target_tag = $TargetTag
        target_commit = $TargetCommit
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $payload | ConvertTo-Json -Depth 20
    $json | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($payload | ConvertTo-Json -Depth 20 -Compress))
    exit $ExitCode
}

function Get-Sha256 {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Stop-BridgeApp {
    $items = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)

    foreach ($process in $items) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        }
        catch {}
    }

    Start-Sleep -Seconds 2

    $items = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    foreach ($process in $items) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        catch {}
    }

    Start-Sleep -Seconds 1
}

function Stop-BridgeWebViewProcesses {
    $profileNeedle = 'ChatGptDesktopLocalBridge\WebView2'
    $items = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -like ('*' + $profileNeedle + '*') })

    foreach ($item in $items) {
        try {
            Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop
        }
        catch {}
    }

    if ($items.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}

function Get-InstalledTag {
    if (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf) {
        try {
            $info = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$info.schema -eq 'chatgpt-desktop-local-bridge-release-v1' -and
                -not [string]::IsNullOrWhiteSpace([string]$info.tag)) {
                return [string]$info.tag
            }
        }
        catch {}
    }

    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D6B9AF8-6D08-44E1-B2F5-8A6341D99165}_is1'
    if (Test-Path -LiteralPath $uninstallKey) {
        try {
            $version = [string](Get-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -ErrorAction Stop).DisplayVersion
            if ($version -eq '0.1.24.0') {
                return 'dev-1d00606'
            }
        }
        catch {}
    }

    return $null
}

function Get-UpdaterSpec {
    param([string]$BaseTag)

    switch ($BaseTag) {
        'dev-1d00606' {
            return @{
                name = 'ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe'
                sha256 = '23f5bb3719897b085846323b3a37a805967926de3008c3d2f4d6e51edb5d6f2e'
            }
        }
        'dev-4ed78c2' {
            return @{
                name = 'ChatGptDesktopLocalBridge-Update-from-dev-4ed78c2.exe'
                sha256 = 'd85f38c48008cf9b4cbfa1c9db852668bdf35d819957814543fdaabaa6493219'
            }
        }
        'dev-7c6aa32' {
            return @{
                name = 'ChatGptDesktopLocalBridge-Update-from-dev-7c6aa32.exe'
                sha256 = 'af1df5023506f49a9e73c1f1c9ec55e32c99a3943f9cbe0ad42acdde1cf59d3b'
            }
        }
        default {
            return $null
        }
    }
}

function Update-ToTarget {
    param([string]$BaseTag)

    if ($BaseTag -eq $TargetTag) {
        return @{
            updated = $false
            from = $BaseTag
        }
    }

    $spec = Get-UpdaterSpec -BaseTag $BaseTag
    if ($null -eq $spec) {
        throw "No verified delta updater is available from installed release '$BaseTag' to '$TargetTag'."
    }

    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

    $assetUrl = 'https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/' +
        $TargetTag + '/' + [string]$spec.name

    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($assetUrl, $UpdaterPath)
    }
    finally {
        $client.Dispose()
    }

    $actualHash = Get-Sha256 -Path $UpdaterPath
    if ($actualHash -ne [string]$spec.sha256) {
        throw "Downloaded updater hash mismatch. Expected $($spec.sha256), got $actualHash."
    }

    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART', '1', 'Process')

    $arguments = @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        ('/LOG=' + $UpdaterLog)
    )

    $process = Start-Process -FilePath $UpdaterPath -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit(180000)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw 'Delta updater timed out after 180 seconds.'
    }

    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        $details = ''
        if (Test-Path -LiteralPath $UpdaterLog -PathType Leaf) {
            $details = (Get-Content -LiteralPath $UpdaterLog -Tail 80 | Out-String)
        }

        $runtimeLog = Join-Path $LogRoot 'update-last.log'
        if (Test-Path -LiteralPath $runtimeLog -PathType Leaf) {
            $details = $details + [Environment]::NewLine + '--- update-last.log ---' + [Environment]::NewLine +
                (Get-Content -LiteralPath $runtimeLog -Tail 100 | Out-String)
        }

        throw "Delta updater failed with exit code $($process.ExitCode). $details"
    }

    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) {
        throw 'Updater returned success but release-info.json is missing.'
    }

    $info = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$info.tag -ne $TargetTag -or [string]$info.commit -ne $TargetCommit) {
        throw "Updated release marker mismatch: tag='$($info.tag)' commit='$($info.commit)'."
    }

    return @{
        updated = $true
        from = $BaseTag
    }
}

function Wait-BridgeProcess {
    param([int]$TimeoutSeconds = 45)

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

function Invoke-UiButton {
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

            if ($target.Count -gt 0) {
                return $target[0]
            }
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
        [hashtable]$Params = @{}
    )

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress

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

            if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
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

function Invoke-CdpEval {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Expression,
        [string]$Stage
    )

    $response = Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }
    $Id.Value++

    return Get-CdpEvalValue -Response $response -Stage $Stage
}

function Wait-AdapterReady {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [int]$TimeoutSeconds = 75
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $last = Invoke-CdpEval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.health?.() ?? null' -Stage 'adapter-health'

            if ($null -ne $last -and
                [int]$last.version -ge 3 -and
                [bool]$last.composerFound -and
                [bool]$last.nativeInputReady) {
                return $last
            }
        }
        catch {}

        Start-Sleep -Milliseconds 500
    }

    throw ('Adapter v3 did not become ready. Last health: ' + ($last | ConvertTo-Json -Depth 10 -Compress))
}

function Send-ChatText {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Text
    )

    $prepare = Invoke-CdpEval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}' -Stage 'chat-prepare'

    if ($null -eq $prepare -or -not [bool]$prepare.accepted) {
        throw ('Chat preflight rejected: ' + ($prepare | ConvertTo-Json -Depth 10 -Compress))
    }

    $insertResponse = Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Input.insertText' -Params @{
        text = $Text
    }
    $Id.Value++

    if ($null -ne $insertResponse.PSObject.Properties['error']) {
        throw ('Input.insertText failed: ' + ($insertResponse.error | ConvertTo-Json -Depth 10 -Compress))
    }

    $expected = $Text | ConvertTo-Json -Compress
    $inserted = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(8)

    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Invoke-CdpEval -Socket $Socket -Id $Id -Expression ('window.__localBridge?.nativeSendState?.(' + $expected + ') ?? null') -Stage 'chat-insert-state'

        if ($null -ne $state -and [bool]$state.textMatches) {
            $inserted = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if (-not $inserted) {
        throw 'Native ChatGPT composer input was not accepted.'
    }

    $submit = Invoke-CdpEval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}' -Stage 'chat-submit'

    if ($null -eq $submit -or -not [bool]$submit.accepted) {
        throw ('Chat submit rejected: ' + ($submit | ConvertTo-Json -Depth 10 -Compress))
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Invoke-CdpEval -Socket $Socket -Id $Id -Expression 'window.__localBridge?.nativeSendState?.() ?? null' -Stage 'chat-submit-state'

        if ($null -ne $state -and [bool]$state.composerEmpty) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw 'Chat submit was not confirmed by composer clear.'
}

function Wait-BridgeReadyStatus {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [int]$TimeoutSeconds = 90
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastTexts = @()

    while ([DateTime]::UtcNow -lt $deadline) {
        $lastTexts = @(Get-UiTexts -Root $Root)

        $ready = @($lastTexts | Where-Object { $_ -like 'Bridge ready. Session*' } | Select-Object -First 1)
        if ($ready.Count -gt 0) {
            return [string]$ready[0]
        }

        $failure = @($lastTexts | Where-Object {
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*' -or
            $_ -like 'Chat send failed:*' -or
            $_ -like 'Bridge error:*'
        } | Select-Object -First 1)

        if ($failure.Count -gt 0) {
            throw ('Bridge initialization failed: ' + [string]$failure[0])
        }

        Start-Sleep -Milliseconds 500
    }

    throw ('Timed out waiting for Bridge ready. UI texts: ' + (@($lastTexts | Select-Object -Last 20) -join ' | '))
}

function Wait-AssistantMarker {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$Id,
        [string]$Marker,
        [int]$TimeoutSeconds = 180
    )

    $markerJson = $Marker | ConvertTo-Json -Compress
    $expression = @'
(() => {
  const nodes = Array.from(document.querySelectorAll(
    "[data-markdown-text-style='assistant-message'], [data-message-author-role='assistant']"
  ));
  const texts = nodes.map(n => (n.innerText || n.textContent || "").trim()).filter(Boolean);
  const marker = __MARKER_JSON__;
  return {
    found: texts.some(t => t === marker || t.includes(marker)),
    texts: texts.slice(-8)
  };
})()
'@
    $expression = $expression.Replace('__MARKER_JSON__', $markerJson)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $last = Invoke-CdpEval -Socket $Socket -Id $Id -Expression $expression -Stage 'assistant-marker'
        if ($null -ne $last -and [bool]$last.found) {
            return $last
        }

        Start-Sleep -Milliseconds 500
    }

    throw ('Timed out waiting for assistant marker. Last assistant texts: ' + ($last | ConvertTo-Json -Depth 10 -Compress))
}

function Find-FsReadAudit {
    param(
        [string]$SessionPrefix,
        [DateTimeOffset]$StartedAfter
    )

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return $null
    }

    $files = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 3)

    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
                $timestamp = [DateTimeOffset]::Parse([string]$record.timestampUtc)

                if ($timestamp -lt $StartedAfter) {
                    continue
                }

                if ([string]$record.session -like ($SessionPrefix + '*') -and
                    [string]$record.tool -eq 'fs.read_text') {
                    return $record
                }
            }
            catch {}
        }
    }

    return $null
}

if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
    Write-ProjectResult -Status 'fail' -ExitCode 10 -ErrorText "Installed bridge executable not found at '$AppExe'."
}

$baseTag = $null
$updateResult = $null
$port = Get-Random -Minimum 9400 -Maximum 9999
$appProcess = $null
$uiRoot = $null
$cdpId = 1
$bridgeReadyText = $null
$sessionPrefix = $null
$marker = 'BRIDGE-M1-FS-READ-PASS-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$testStarted = [DateTimeOffset]::UtcNow

try {
    $baseTag = Get-InstalledTag
    if ([string]::IsNullOrWhiteSpace($baseTag)) {
        throw 'Installed release could not be identified safely.'
    }

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses

    $updateResult = Update-ToTarget -BaseTag $baseTag

    Stop-BridgeApp
    Stop-BridgeWebViewProcesses

    [Environment]::SetEnvironmentVariable(
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
        ('--remote-debugging-port=' + $port + ' --remote-allow-origins=*'),
        'Process')

    Start-Process -FilePath $AppExe | Out-Null

    $appProcess = Wait-BridgeProcess -TimeoutSeconds 45
    if ($null -eq $appProcess) {
        throw 'Updated application main window did not appear.'
    }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $uiRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$appProcess.MainWindowHandle)
    if ($null -eq $uiRoot) {
        throw 'UI Automation root is unavailable.'
    }

    $target = Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
    if ($null -eq $target) {
        throw 'Updated WebView2 CDP target did not appear.'
    }

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    [void](Send-CdpCommand -Socket $socket -Id $cdpId -Method 'Page.navigate' -Params @{
        url = 'https://chatgpt.com/'
    })
    $cdpId++

    $health = Wait-AdapterReady -Socket $socket -Id ([ref]$cdpId) -TimeoutSeconds 75

    Invoke-UiButton -Root $uiRoot -Name 'Initialize Bridge'
    $bridgeReadyText = Wait-BridgeReadyStatus -Root $uiRoot -TimeoutSeconds 90

    if ($bridgeReadyText -match 'Session\s+([0-9a-fA-F]{8})') {
        $sessionPrefix = $Matches[1].ToLowerInvariant()
    }
    else {
        throw "Could not parse bridge session prefix from '$bridgeReadyText'."
    }

    $prompt = 'Use the Local Bridge now. Call fs.read_text for C:\Windows\win.ini with max_chars 4096. ' +
        'Wait for the LOCAL_BRIDGE_RESULT_V1. If the tool result is successful, reply with exactly this single line and no other text: ' +
        $marker + '. If the tool fails, do not use that marker.'

    Send-ChatText -Socket $socket -Id ([ref]$cdpId) -Text $prompt

    $assistant = Wait-AssistantMarker -Socket $socket -Id ([ref]$cdpId) -Marker $marker -TimeoutSeconds 180

    $auditDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $audit = $null

    while ([DateTime]::UtcNow -lt $auditDeadline) {
        $audit = Find-FsReadAudit -SessionPrefix $sessionPrefix -StartedAfter $testStarted
        if ($null -ne $audit) {
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $audit) {
        throw "Assistant returned the pass marker, but no matching fs.read_text audit record was found for session $sessionPrefix."
    }

    if (-not [bool]$audit.ok) {
        throw ('fs.read_text audit record is not successful: ' + ($audit | ConvertTo-Json -Depth 10 -Compress))
    }

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        installed_before = $baseTag
        updated = [bool]$updateResult.updated
        installed_after = $TargetTag
        adapter_version = [int]$health.version
        native_input_ready = [bool]$health.nativeInputReady
        bridge_ready = $bridgeReadyText
        session_prefix = $sessionPrefix
        fs_read_audit_ok = [bool]$audit.ok
        fs_read_elapsed_ms = [long]$audit.elapsedMs
        assistant_marker = $marker
        assistant_marker_seen = [bool]$assistant.found
    }
}
catch {
    $extra = @{
        installed_before = $baseTag
        bridge_ready = $bridgeReadyText
        session_prefix = $sessionPrefix
        test_marker = $marker
    }

    if ($null -ne $updateResult) {
        $extra['updated'] = [bool]$updateResult.updated
    }

    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra $extra
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

    [Environment]::SetEnvironmentVariable(
        'CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',
        $oldSkipRestart,
        'Process')

    try {
        if ($leaveAppRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
            Start-Process -FilePath $AppExe | Out-Null
        }
    }
    catch {}

    try {
        if (Test-Path -LiteralPath $TempRoot) {
            Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}
