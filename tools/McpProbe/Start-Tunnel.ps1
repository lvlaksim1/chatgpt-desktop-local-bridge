# Local-only launcher for the isolated read-only MCP probe.
# Runtime key is entered privately; only its user-scoped DPAPI ciphertext is cached on disk.
param([string] $TunnelId = "")

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe = Join-Path $root ".tools\tunnel-client-v0.0.18\tunnel-client.exe"
$dll = Join-Path $PSScriptRoot "bin\Release\net8.0\McpProbe.dll"
$profiles = Join-Path $root ".tools\tunnel-profiles"
$healthUrlFile = Join-Path $root ".tools\tunnel-client-health.url"
$profileName = "local-bridge-probe"
$logDirectory = Join-Path $env:LOCALAPPDATA "ChatGptDesktopLocalBridge\McpProbe"
$statePath = Join-Path $logDirectory "tunnel-state.json"
$doctorLog = Join-Path $logDirectory "doctor.log"
$runtimeLog = Join-Path $logDirectory "runtime.log"
$plainKey = $null
$encryptedKeyFile = Join-Path $logDirectory "runtime-key.dpapi"
$keyWasEntered = $false
$encryptedKeyToSave = $null

New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
function Set-State([string] $stage, [string] $detail) {
    $state = @{
        timestamp = (Get-Date).ToString("o")
        stage = $stage
        detail = $detail
        tunnel_id = $TunnelId
        diagnostics_dir = $logDirectory
    }
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $statePath -Encoding UTF8
}
Set-State "started" "Checking local prerequisites."

try {
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Official tunnel-client executable missing: $exe" }
    if (!(Test-Path -LiteralPath $dll -PathType Leaf)) { throw "Build MCP probe first: $dll" }
    if (!$TunnelId) { $TunnelId = Read-Host "Enter your OpenAI Platform tunnel ID" }
    $TunnelId = $TunnelId.Trim()
    if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9_.:-]+$') { throw "Invalid tunnel ID." }

    # Windows DPAPI protects the cached key for the current Windows account.
    # The file stores only encrypted material, not the plaintext API key.
    if (Test-Path -LiteralPath $encryptedKeyFile -PathType Leaf) {
        try {
            $ciphertext = (Get-Content -LiteralPath $encryptedKeyFile -Raw -ErrorAction Stop).Trim()
            $secureKey = ConvertTo-SecureString -String $ciphertext -ErrorAction Stop
            Write-Output "Using saved Windows-protected runtime key."
        } catch {
            throw "Saved runtime key cannot be decrypted. Delete runtime-key.dpapi and restart."
        }
    } else {
        $secureKey = Read-Host "Enter your tunnel runtime API key (input hidden)" -AsSecureString
        $keyWasEntered = $true
    }
    if ($secureKey.Length -eq 0) { throw "An API key is required." }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $env:CONTROL_PLANE_API_KEY = $plainKey
        if ($keyWasEntered) { $encryptedKeyToSave = ConvertFrom-SecureString -SecureString $secureKey }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secureKey.Dispose()
    }

    Set-State "configuring" "Creating isolated local MCP profile."
    New-Item -ItemType Directory -Force -Path $profiles | Out-Null
    # tunnel-client parses backslash as a quoting escape (including on Windows).
    # Use Windows-compatible forward slashes so Go's argv parser keeps the DLL path intact.
    $mcpDllArgument = $dll.Replace([char]92, [char]47)
    $launchCommand = 'dotnet "' + $mcpDllArgument + '"'
    & $exe init --sample sample_mcp_stdio_local --profile $profileName --profile-dir $profiles --tunnel-id $TunnelId --mcp-command $launchCommand --health-listen-addr "127.0.0.1:0" --force
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client init failed (exit $LASTEXITCODE)." }

    Set-State "doctor" "Checking tunnel configuration and account permissions."
    Write-Output "Checking tunnel configuration and access..."
    $diagnostic = & $exe doctor --profile $profileName --profile-dir $profiles --explain 2>&1
    $doctorCode = $LASTEXITCODE
    $safeOutput = ($diagnostic | Out-String)
    if ($plainKey) { $safeOutput = $safeOutput.Replace($plainKey, "[REDACTED]") }
    [IO.File]::WriteAllText($doctorLog, $safeOutput, [Text.Encoding]::UTF8)
    Write-Output $safeOutput
    if ($doctorCode -ne 0) { throw "Tunnel doctor failed (exit $doctorCode); see $doctorLog" }

    # Unlike doctor, this confirms the runtime key can access the actual tunnel.
    Set-State "validating_access" "Checking access to the configured tunnel."
    & $exe admin tunnels get $TunnelId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to fetch tunnel metadata with the runtime key. No key was saved." }
    if ($keyWasEntered) {
        [IO.File]::WriteAllText($encryptedKeyFile, $encryptedKeyToSave, [Text.Encoding]::UTF8)
        Write-Output "Runtime key stored in Windows DPAPI-protected form for next launches."
    }

    if (Test-Path $healthUrlFile) { Remove-Item -LiteralPath $healthUrlFile -Force }
    Set-State "connecting" "Tunnel daemon starting; check health URL and runtime log."
    Write-Output "Connecting read-only MCP probe. Press Ctrl+C to stop."
    Write-Output "Local diagnostic files: $logDirectory"
    & $exe run --profile $profileName --profile-dir $profiles --health.url-file $healthUrlFile --log.file $runtimeLog
    $runExit = $LASTEXITCODE
    Set-State "stopped" "Tunnel-client exited with code $runExit. See runtime.log."
    if ($runExit -ne 0) { throw "tunnel-client run failed (exit $runExit); see $runtimeLog" }
} catch {
    $message = $_.Exception.Message
    if ($plainKey) { $message = $message.Replace($plainKey, "[REDACTED]") }
    Set-State "failed" $message
    Write-Output "ERROR: $message"
    exit 1
} finally {
    Remove-Item Env:\CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue
    $plainKey = $null
}
