param()

$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $packageRoot "update-manifest.json"
$payloadRoot = Join-Path $packageRoot "payload"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\ChatGPT Desktop Local Bridge"
$appExe = Join-Path $installDir "ChatGptDesktopLocalBridge.exe"
$processName = "ChatGptDesktopLocalBridge"

function Normalize-RelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Manifest contains an empty path."
    }

    $normalized = $Path.Replace("/", "\")
    if ([System.IO.Path]::IsPathRooted($normalized) -or
        $normalized -eq ".." -or
        $normalized.StartsWith("..\") -or
        $normalized.Contains("\..\")) {
        throw "Unsafe relative path in update manifest: $Path"
    }

    return $normalized
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ExpectedFile([string]$Root, $Entry) {
    $relative = Normalize-RelativePath $Entry.path
    $fullPath = Join-Path $Root $relative

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Base version mismatch: missing file '$relative'. Use the full Setup installer."
    }

    $actual = Get-Sha256 $fullPath
    $expected = ([string]$Entry.sha256).ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Base version mismatch for '$relative'. Use the full Setup installer."
    }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "update-manifest.json is missing."
}

if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
    throw "Installed application was not found at '$installDir'. Use the full Setup installer."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schema -ne "chatgpt-desktop-local-bridge-delta-v1") {
    throw "Unsupported update manifest schema."
}

Write-Host "Validating installed base: $($manifest.fromTag)"
foreach ($entry in @($manifest.baseline)) {
    Assert-ExpectedFile $installDir $entry
}

$running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
foreach ($process in $running) {
    try {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    } catch {
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds(8)
while ((Get-Process -Name $processName -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 250
}

Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$backupRoot = Join-Path $env:TEMP ("ChatGptDesktopLocalBridge-update-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$hadOriginal = @{}

try {
    foreach ($entry in @($manifest.files)) {
        $relative = Normalize-RelativePath $entry.path
        $destination = Join-Path $installDir $relative
        $source = Join-Path $payloadRoot $relative

        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Update payload is missing '$relative'."
        }

        $payloadHash = Get-Sha256 $source
        if ($payloadHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
            throw "Update payload hash mismatch for '$relative'."
        }

        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        $hadOriginal[$relative] = $exists

        if ($exists) {
            $backupPath = Join-Path $backupRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backupPath -Force
        }
    }

    foreach ($relativeRaw in @($manifest.delete)) {
        $relative = Normalize-RelativePath ([string]$relativeRaw)
        $destination = Join-Path $installDir $relative
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        $hadOriginal[$relative] = $exists

        if ($exists) {
            $backupPath = Join-Path $backupRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backupPath -Force
        }
    }

    foreach ($entry in @($manifest.files)) {
        $relative = Normalize-RelativePath $entry.path
        $destination = Join-Path $installDir $relative
        $source = Join-Path $payloadRoot $relative

        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    foreach ($relativeRaw in @($manifest.delete)) {
        $relative = Normalize-RelativePath ([string]$relativeRaw)
        $destination = Join-Path $installDir $relative
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }

    foreach ($entry in @($manifest.files)) {
        $relative = Normalize-RelativePath $entry.path
        $destination = Join-Path $installDir $relative
        $actual = Get-Sha256 $destination
        if ($actual -ne ([string]$entry.sha256).ToLowerInvariant()) {
            throw "Post-update verification failed for '$relative'."
        }
    }

    foreach ($relativeRaw in @($manifest.delete)) {
        $relative = Normalize-RelativePath ([string]$relativeRaw)
        if (Test-Path -LiteralPath (Join-Path $installDir $relative)) {
            throw "Post-update verification failed: '$relative' should have been removed."
        }
    }

    Write-Host "Update complete: $($manifest.fromTag) -> $($manifest.toTag)"
}
catch {
    Write-Warning "Update failed. Rolling back changed files."

    foreach ($entry in @($manifest.files)) {
        $relative = Normalize-RelativePath $entry.path
        $destination = Join-Path $installDir $relative
        $backupPath = Join-Path $backupRoot $relative

        if ($hadOriginal[$relative]) {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $backupPath -Destination $destination -Force
            }
        }
        elseif (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }

    foreach ($relativeRaw in @($manifest.delete)) {
        $relative = Normalize-RelativePath ([string]$relativeRaw)
        $destination = Join-Path $installDir $relative
        $backupPath = Join-Path $backupRoot $relative

        if ($hadOriginal[$relative] -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $backupPath -Destination $destination -Force
        }
    }

    throw
}
finally {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Start-Process -FilePath $appExe
