param(
    [string]$BasePublishDir,

    [string]$BaseManifestPath,

    [string]$LegacyInstallerVersion,

    [Parameter(Mandatory = $true)]
    [string]$CurrentPublishDir,

    [Parameter(Mandatory = $true)]
    [string]$BaseTag,

    [Parameter(Mandatory = $true)]
    [string]$TargetTag,

    [Parameter(Mandatory = $true)]
    [string]$TargetCommit,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Get-PublishMap([string]$Root) {
    $rootPath = (Resolve-Path $Root).Path.TrimEnd("\")
    $map = @{}

    Get-ChildItem -LiteralPath $rootPath -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length).TrimStart("\").Replace("\", "/")
        $map[$relative] = [pscustomobject]@{
            path = $relative
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            size = $_.Length
        }
    }

    return $map
}

function Get-ManifestMap([string]$ManifestPath, [string]$ExpectedTag) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    if ($manifest.schema -ne "chatgpt-desktop-local-bridge-publish-v1") {
        throw "Unsupported base publish manifest schema."
    }

    if ($manifest.tag -ne $ExpectedTag) {
        throw "Base publish manifest tag mismatch. Expected '$ExpectedTag', got '$($manifest.tag)'."
    }

    $map = @{}
    foreach ($entry in @($manifest.files)) {
        $map[[string]$entry.path] = [pscustomobject]@{
            path = [string]$entry.path
            sha256 = ([string]$entry.sha256).ToLowerInvariant()
            size = [long]$entry.size
        }
    }

    return $map
}

if ([string]::IsNullOrWhiteSpace($BasePublishDir) -eq [string]::IsNullOrWhiteSpace($BaseManifestPath)) {
    throw "Provide exactly one of BasePublishDir or BaseManifestPath."
}

$validationMode = "exact"
$legacyInstallerVersionValue = $null

if (-not [string]::IsNullOrWhiteSpace($BaseManifestPath)) {
    Write-Host "Using exact release manifest for base $BaseTag"
    $comparisonBase = Get-ManifestMap $BaseManifestPath $BaseTag
    $validationBase = $comparisonBase
}
else {
    $comparisonBase = Get-PublishMap $BasePublishDir

    if (-not [string]::IsNullOrWhiteSpace($LegacyInstallerVersion)) {
        $validationMode = "legacy-installer-fingerprint"
        $legacyInstallerVersionValue = $LegacyInstallerVersion
        $validationBase = @{}

        foreach ($path in @(
            "Config/permissions.default.json",
            "Web/bridge-adapter.js"
        )) {
            if (-not $comparisonBase.ContainsKey($path)) {
                throw "Legacy fingerprint file '$path' is missing from reconstructed base."
            }

            $validationBase[$path] = $comparisonBase[$path]
        }

        Write-Warning "Using legacy installer version + stable-file fingerprint for base $BaseTag."
    }
    else {
        Write-Warning "Base $BaseTag has no exact release manifest; using reconstructed publish for exact validation."
        $validationBase = $comparisonBase
    }
}

$current = Get-PublishMap $CurrentPublishDir

$changed = @()
foreach ($path in ($current.Keys | Sort-Object)) {
    if (-not $comparisonBase.ContainsKey($path) -or $comparisonBase[$path].sha256 -ne $current[$path].sha256) {
        $changed += $current[$path]
    }
}

$deleted = @($comparisonBase.Keys | Where-Object { -not $current.ContainsKey($_) } | Sort-Object)
$baseline = @($validationBase.Values | Sort-Object path)

$staging = Join-Path $env:TEMP ("ChatGptDesktopLocalBridge-delta-" + [Guid]::NewGuid().ToString("N"))
$payload = Join-Path $staging "payload"
New-Item -ItemType Directory -Path $payload -Force | Out-Null

try {
    foreach ($entry in $changed) {
        $source = Join-Path $CurrentPublishDir ($entry.path.Replace("/", "\"))
        $destination = Join-Path $payload ($entry.path.Replace("/", "\"))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "update\Apply-Update.ps1") -Destination (Join-Path $staging "Apply-Update.ps1")

    $manifest = [ordered]@{
        schema = "chatgpt-desktop-local-bridge-delta-v1"
        fromTag = $BaseTag
        toTag = $TargetTag
        targetCommit = $TargetCommit
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        baseValidationMode = $validationMode
        legacyInstallerVersion = $legacyInstallerVersionValue
        baseline = $baseline
        files = $changed
        delete = $deleted
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $staging "update-manifest.json") -Encoding UTF8

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Recurse -Force
    }

    Copy-Item -LiteralPath $staging -Destination $OutputPath -Recurse

    $payloadBytes = ($changed | Measure-Object -Property size -Sum).Sum
    if ($null -eq $payloadBytes) { $payloadBytes = 0 }

    Write-Host "Delta $BaseTag -> $TargetTag"
    Write-Host "Validation mode: $validationMode"
    Write-Host "Changed files: $($changed.Count)"
    Write-Host "Deleted files: $($deleted.Count)"
    Write-Host "Payload bytes: $payloadBytes"
    Write-Host "Staging directory: $OutputPath"
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
