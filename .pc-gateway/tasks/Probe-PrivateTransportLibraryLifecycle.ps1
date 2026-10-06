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
$port = Get-Random -Minimum 9400 -Maximum 9999
$cdpId = 1

try {
    if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf)) { throw "Installed application is missing at '$AppExe'." }
    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) { throw 'release-info.json is missing.' }

    $release = Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedTag = [string]$release.tag
    if ($installedTag -ne $ExpectedTag) { throw "Installed release '$installedTag' is not the expected '$ExpectedTag'." }

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

    $script = @"
(async () => {
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  const marker = 'bridge-library-probe-' + crypto.randomUUID().replaceAll('-', '').slice(0, 12);
  const fileName = marker + '.json';
  const renamedName = marker + '-renamed.json';
  const text = JSON.stringify({ schema: 'local-bridge-library-probe-v1', marker });
  const bytes = new TextEncoder().encode(text);

  async function authContext() {
    const response = await fetch('/api/auth/session', {
      method: 'GET', credentials: 'include', cache: 'no-store', redirect: 'error',
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

  async function jsonApi(method, path, body) {
    const h = { ...headers };
    const init = { method, credentials: 'include', redirect: 'error', cache: 'no-store', headers: h };
    if (body !== undefined) {
      h['content-type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    const response = await fetch(path, init);
    const raw = await response.text();
    let json = null;
    try { json = raw ? JSON.parse(raw) : null; } catch {}
    return { ok: response.ok, status: response.status, json, raw };
  }

  async function textApi(method, path, body) {
    const h = { ...headers };
    const init = { method, credentials: 'include', redirect: 'error', cache: 'no-store', headers: h };
    if (body !== undefined) {
      h['content-type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    const response = await fetch(path, init);
    const raw = await response.text();
    return { ok: response.ok, status: response.status, raw };
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

  async function listLibrary() {
    const r = await jsonApi('POST', '/backend-api/files/library', { limit: 100 });
    if (!r.ok || !Array.isArray(r.json?.items)) throw new Error('library_list_http_' + r.status);
    return r.json.items;
  }

  async function findLibraryFile(fileId) {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const items = await listLibrary();
      const found = items.find(x => x && x.file_id === fileId);
      if (found) return found;
      await delay(300);
    }
    return null;
  }

  async function softDelete(libId, fileId, name, parentId) {
    const url = new URL('/backend-api/files/library/files/' + encodeURIComponent(libId) + '/delete_stream', location.origin);
    url.searchParams.set('file_id', fileId);
    if (parentId != null) url.searchParams.set('parent_directory_id', String(parentId));
    url.searchParams.set('file_name', name);
    url.searchParams.set('soft_delete', 'true');
    const r = await textApi('POST', url.pathname + url.search);
    const events = parseNdjson(r.raw);
    const completed = events.some(x => x?.event === 'file.deletion.completed');
    return { status: r.status, completed };
  }

  const summary = {
    pass: false,
    code: 'started',
    marker,
    prepareStatus: 0,
    uploadStatus: 0,
    processStatus: 0,
    processCompleted: false,
    libraryLocated: false,
    downloadStatus: 0,
    downloadExact: false,
    renameStatus: 0,
    renameReadback: false,
    deleteStatus: 0,
    deleteCompleted: false,
    cleanupAttempted: false,
    fileId: null,
    libraryFileId: null
  };

  let fileId = null;
  let libId = null;
  let currentName = fileName;
  let parentId = null;

  try {
    const prepared = await jsonApi('POST', '/backend-api/files', {
      file_name: fileName,
      file_size: bytes.byteLength,
      use_case: 'ace_upload',
      timezone_offset_min: new Date().getTimezoneOffset(),
      reset_rate_limits: false,
      supports_direct_azure_multipart: false,
      mime_type: 'application/json',
      entry_surface: 'chat_composer',
      store_in_library: true,
      library_persistence_mode: 'required'
    });
    summary.prepareStatus = prepared.status;
    if (!prepared.ok || prepared.json?.status !== 'success' ||
        typeof prepared.json?.file_id !== 'string' ||
        typeof prepared.json?.upload_url !== 'string') {
      throw new Error('prepare_http_' + prepared.status);
    }

    fileId = prepared.json.file_id;
    summary.fileId = fileId;
    const uploadUrl = new URL(prepared.json.upload_url);
    if (uploadUrl.protocol !== 'https:' ||
        !uploadUrl.hostname.endsWith('.oaiusercontent.com') ||
        !uploadUrl.search) throw new Error('unsafe_upload_url');

    const aws = Array.from(uploadUrl.searchParams.keys())
      .some(key => key.toLowerCase() === 'x-amz-algorithm');
    const uploadHeaders = aws
      ? { 'Content-Type': 'application/json' }
      : { 'Content-Type': 'application/json', 'x-ms-blob-type': 'BlockBlob', 'x-ms-version': '2020-04-08' };

    const uploaded = await fetch(uploadUrl.href, {
      method: 'PUT',
      credentials: 'omit',
      redirect: 'error',
      headers: uploadHeaders,
      body: bytes
    });
    summary.uploadStatus = uploaded.status;
    if (!uploaded.ok) throw new Error('upload_http_' + uploaded.status);

    const processed = await textApi('POST', '/backend-api/files/process_upload_stream', {
      file_id: fileId,
      file_name: fileName,
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
    summary.processStatus = processed.status;
    if (!processed.ok) throw new Error('process_http_' + processed.status);
    const processEvents = parseNdjson(processed.raw);
    const final = processEvents.findLast
      ? processEvents.findLast(x => x?.event === 'file.processing.completed' && x?.file_id === fileId && x?.progress === 100)
      : processEvents.slice().reverse().find(x => x?.event === 'file.processing.completed' && x?.file_id === fileId && x?.progress === 100);
    if (!final) throw new Error('processing_unconfirmed');
    summary.processCompleted = true;

    if (typeof final?.extra?.metadata_object_id === 'string') libId = final.extra.metadata_object_id;

    const listed = await findLibraryFile(fileId);
    if (!listed) throw new Error('library_file_not_found');
    summary.libraryLocated = true;
    if (!libId && typeof listed.id === 'string') libId = listed.id;
    parentId = listed.directory_id ?? listed.parent_directory_id ?? null;
    if (!libId) throw new Error('library_file_id_missing');
    summary.libraryFileId = libId;

    const downloaded = await fetch(
      '/api/library/files/' + encodeURIComponent(libId) + '/download',
      { method: 'GET', credentials: 'include', redirect: 'follow', cache: 'no-store' }
    );
    summary.downloadStatus = downloaded.status;
    if (!downloaded.ok) throw new Error('download_http_' + downloaded.status);
    const downloadedText = await downloaded.text();
    summary.downloadExact = downloadedText === text;
    if (!summary.downloadExact) throw new Error('download_content_mismatch');

    const renamed = await jsonApi(
      'PATCH',
      '/backend-api/files/library/files/' + encodeURIComponent(libId),
      { file_name: renamedName }
    );
    summary.renameStatus = renamed.status;
    if (!renamed.ok) throw new Error('rename_http_' + renamed.status);
    currentName = renamedName;

    const renameDeadline = Date.now() + 12000;
    while (Date.now() < renameDeadline) {
      const items = await listLibrary();
      const found = items.find(x => x && x.id === libId);
      if (found && found.file_name === renamedName) {
        summary.renameReadback = true;
        parentId = found.directory_id ?? found.parent_directory_id ?? parentId;
        break;
      }
      await delay(300);
    }
    if (!summary.renameReadback) throw new Error('rename_readback_timeout');

    const deleted = await softDelete(libId, fileId, currentName, parentId);
    summary.deleteStatus = deleted.status;
    summary.deleteCompleted = deleted.completed;
    summary.cleanupAttempted = true;
    if (!(deleted.status >= 200 && deleted.status < 300 && deleted.completed)) {
      throw new Error('delete_unconfirmed');
    }

    summary.pass =
      summary.prepareStatus >= 200 && summary.prepareStatus < 300 &&
      summary.uploadStatus >= 200 && summary.uploadStatus < 300 &&
      summary.processCompleted &&
      summary.libraryLocated &&
      summary.downloadExact &&
      summary.renameReadback &&
      summary.deleteCompleted;
    summary.code = summary.pass ? 'pass' : 'assertion_failed';
    return summary;
  } catch (error) {
    summary.code = 'exception';
    summary.error = String(error);

    if (libId && fileId && !summary.deleteCompleted) {
      summary.cleanupAttempted = true;
      try {
        const deleted = await softDelete(libId, fileId, currentName, parentId);
        summary.deleteStatus = deleted.status;
        summary.deleteCompleted = deleted.completed;
      } catch {}
    } else if (fileId && !libId) {
      try {
        const listed = await findLibraryFile(fileId);
        if (listed && typeof listed.id === 'string') {
          libId = listed.id;
          summary.libraryFileId = libId;
          summary.cleanupAttempted = true;
          const deleted = await softDelete(
            libId,
            fileId,
            listed.file_name || currentName,
            listed.directory_id ?? listed.parent_directory_id ?? null
          );
          summary.deleteStatus = deleted.status;
          summary.deleteCompleted = deleted.completed;
        }
      } catch {}
    }
    return summary;
  }
})()
"@

    $result = Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'library-lifecycle' -TimeoutMs 120000
    $safe = [ordered]@{
        pass = [bool]$result.pass
        code = [string]$result.code
        marker = [string]$result.marker
        prepare_http = [int]$result.prepareStatus
        upload_http = [int]$result.uploadStatus
        process_http = [int]$result.processStatus
        process_completed = [bool]$result.processCompleted
        library_located = [bool]$result.libraryLocated
        download_http = [int]$result.downloadStatus
        download_exact = [bool]$result.downloadExact
        rename_http = [int]$result.renameStatus
        rename_readback = [bool]$result.renameReadback
        delete_http = [int]$result.deleteStatus
        delete_completed = [bool]$result.deleteCompleted
        cleanup_attempted = [bool]$result.cleanupAttempted
        error = if ($null -ne $result.PSObject.Properties['error']) { [string]$result.error } else { '' }
    }
    Write-Host ('LIBRARY_LIFECYCLE_RESULT=' + ($safe | ConvertTo-Json -Compress))

    if (-not [bool]$result.pass) {
        throw ('Library lifecycle probe failed: ' + ($safe | ConvertTo-Json -Compress))
    }

    Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{
        installed_tag = $installedTag
        marker = [string]$result.marker
        prepare_http = [int]$result.prepareStatus
        upload_http = [int]$result.uploadStatus
        process_http = [int]$result.processStatus
        process_completed = [bool]$result.processCompleted
        library_located = [bool]$result.libraryLocated
        download_http = [int]$result.downloadStatus
        download_exact = [bool]$result.downloadExact
        rename_http = [int]$result.renameStatus
        rename_readback = [bool]$result.renameReadback
        delete_http = [int]$result.deleteStatus
        delete_completed = [bool]$result.deleteCompleted
    }
}
catch {
    Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        installed_tag = $installedTag
    }
}
finally {
    if ($null -ne $socket) { try { $socket.Dispose() } catch {} }
    try { Stop-BridgeApp } catch {}
    try { Stop-BridgeWebViewProcesses } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}