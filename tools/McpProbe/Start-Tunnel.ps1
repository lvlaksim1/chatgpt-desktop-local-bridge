# Local-only launcher for the isolated, read-only MCP connectivity probe.
# Runtime key is requested interactively and held only in the process environment.
param([string] $TunnelId = "")

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe = Join-Path $root ".tools\tunnel-client-v0.0.18\tunnel-client.exe"
$dll = Join-Path $PSScriptRoot "bin\Release\net8.0\McpProbe.dll"
$profiles = Join-Path $root ".tools\tunnel-profiles"
$healthUrlFile = Join-Path $root ".tools\tunnel-client-health.url"
$profileName = "local-bridge-probe"

if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Official tunnel-client executable missing: $exe" }
if (!(Test-Path -LiteralPath $dll -PathType Leaf)) { throw "Build the MCP probe first: $dll" }
if (!$TunnelId) { $TunnelId = Read-Host "Enter your OpenAI Platform tunnel_id" }
$TunnelId = $TunnelId.Trim()
if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9_.:-]+$') { throw "Invalid tunnel_id. Copy the value from Platform tunnel settings." }

$secureKey = Read-Host "Enter your runtime API key (input hidden)" -AsSecureString
if ($secureKey.Length -eq 0) { throw "API key is required." }
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $env:CONTROL_PLANE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secureKey.Dispose()
}

try {
    New-Item -ItemType Directory -Force -Path $profiles | Out-Null
    $launchCommand = 'dotnet "' + $dll + '"'
    & $exe init --sample sample_mcp_stdio_local --profile $profileName --profile-dir $profiles --tunnel-id $TunnelId --mcp-command $launchCommand --health-listen-addr "127.0.0.1:0" --force
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client init failed: $LASTEXITCODE" }
    Write-Output "Checking tunnel configuration and access..."
    & $exe doctor --profile $profileName --profile-dir $profiles --explain
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client doctor failed: $LASTEXITCODE" }
    Write-Output "Starting read-only MCP tunnel. Press Ctrl+C to stop it."
    & $exe run --profile $profileName --profile-dir $profiles --health.url-file $healthUrlFile
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client run failed: $LASTEXITCODE" }
} finally {
    Remove-Item Env:\CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue
}
