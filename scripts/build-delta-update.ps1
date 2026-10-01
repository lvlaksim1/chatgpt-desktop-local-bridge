param(
    [Parameter(Mandatory = $true)]
    [string]$BasePublishDir,

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

$base = Get-PublishMap $BasePublishDir
$current = Get-PublishMap $CurrentPublishDir

$changed = New-Object System.Collections.Generic.List[object]
foreach ($path in ($current.Keys | Sort-Object)) {
    if (-not $base.ContainsKey($path) -or $base[$path].sha256 -ne $current[$path].sha256) {
        $changed.Add($current[$path])
    }
}

$deleted = @($base.Keys | Where-Object { -not $current.ContainsKey($_) } | Sort-Object)
$baseline = @($base.Values | Sort-Object path)

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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "update\Apply-Update.cmd") -Destination (Join-Path $staging "Apply-Update.cmd")

    $manifest = [ordered]@{
        schema = "chatgpt-desktop-local-bridge-delta-v1"
        fromTag = $BaseTag
        toTag = $TargetTag
        targetCommit = $TargetCommit
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        baseline = $baseline
        files = @($changed)
        delete = $deleted
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $staging "update-manifest.json") -Encoding UTF8

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $OutputPath -CompressionLevel Optimal

    $payloadBytes = ($changed | Measure-Object -Property size -Sum).Sum
    if ($null -eq $payloadBytes) { $payloadBytes = 0 }

    Write-Host "Delta $BaseTag -> $TargetTag"
    Write-Host "Changed files: $($changed.Count)"
    Write-Host "Deleted files: $($deleted.Count)"
    Write-Host "Payload bytes: $payloadBytes"
    Write-Host "Output: $OutputPath"
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
