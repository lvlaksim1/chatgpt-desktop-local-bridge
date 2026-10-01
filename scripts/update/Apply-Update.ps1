param()

$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $packageRoot "update-manifest.json"
$payloadRoot = Join-Path $packageRoot "payload"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\ChatGPT Desktop Local Bridge"
$appExe = Join-Path $installDir "ChatGptDesktopLocalBridge.exe"
$releaseInfoPath = Join-Path $installDir "release-info.json"
$uninstallWrapperPath = Join-Path $installDir "Support\Uninstall-Bridge.ps1"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$processName = "ChatGptDesktopLocalBridge"
$successMarker = Join-Path $packageRoot "update-success.marker"
Remove-Item -LiteralPath $successMarker -Force -ErrorAction SilentlyContinue
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D6B9AF8-6D08-44E1-B2F5-8A6341D99165}_is1"
$updateLogDir = Join-Path $env:LOCALAPPDATA "ChatGptDesktopLocalBridge\logs"
$updateLogPath = Join-Path $updateLogDir "update-last.log"
New-Item -ItemType Directory -Path $updateLogDir -Force | Out-Null

try {
    Start-Transcript -LiteralPath $updateLogPath -Force | Out-Null
}
catch {
    Write-Warning "Could not start update transcript: $($_.Exception.Message)"
}

Write-Host "Updater log: $updateLogPath"

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
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
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

function Assert-LegacyInstallerVersion([string]$ExpectedVersion) {
    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        throw "Legacy update manifest does not specify an installer version."
    }

    if (-not (Test-Path -LiteralPath $uninstallKey)) {
        throw "Legacy base version cannot be verified: installer registration is missing."
    }

    $installed = (Get-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -ErrorAction Stop).DisplayVersion
    if ([string]$installed -ne $ExpectedVersion) {
        throw "Base version mismatch: installed version is '$installed', expected '$ExpectedVersion'. Use the full Setup installer."
    }
}

function Assert-ReleaseMarker([string]$ExpectedTag) {
    if (-not (Test-Path -LiteralPath $releaseInfoPath -PathType Leaf)) {
        throw "Base version mismatch: release-info.json is missing. Use the full Setup installer."
    }

    $info = Get-Content -LiteralPath $releaseInfoPath -Raw | ConvertFrom-Json
    if ($info.schema -ne "chatgpt-desktop-local-bridge-release-v1") {
        throw "Installed release marker has an unsupported schema."
    }

    if ([string]$info.tag -ne $ExpectedTag) {
        throw "Base version mismatch: installed release is '$($info.tag)', expected '$ExpectedTag'."
    }
}

function Register-UninstallWrapper {
    if (-not (Test-Path -LiteralPath $uninstallWrapperPath -PathType Leaf)) {
        throw "Uninstall wrapper is missing from the target release."
    }

    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell was not found."
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstallWrapperPath + '" -InstallWrapper'
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

    if ($process.ExitCode -ne 0) {
        throw "Uninstall wrapper registration failed with exit code $($process.ExitCode)."
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

$validationMode = [string]$manifest.baseValidationMode
if ([string]::IsNullOrWhiteSpace($validationMode)) {
    $validationMode = "exact"
}

Write-Host "Validating installed base: $($manifest.fromTag)"

switch ($validationMode) {
    "legacy-installer-fingerprint" {
        Assert-LegacyInstallerVersion ([string]$manifest.legacyInstallerVersion)

        if (Test-Path -LiteralPath $releaseInfoPath -PathType Leaf) {
            throw "This legacy migration package must not be applied to a marker-based installation."
        }
    }

    "exact" {
        Assert-ReleaseMarker ([string]$manifest.fromTag)
    }

    default {
        throw "Unsupported base validation mode '$validationMode'."
    }
}

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

    if (-not (Test-Path -LiteralPath $releaseInfoPath -PathType Leaf)) {
        throw "Post-update verification failed: release-info.json is missing."
    }

    $targetInfo = Get-Content -LiteralPath $releaseInfoPath -Raw | ConvertFrom-Json
    if ($targetInfo.schema -ne "chatgpt-desktop-local-bridge-release-v1" -or
        [string]$targetInfo.tag -ne [string]$manifest.toTag) {
        throw "Post-update verification failed: release marker does not match target."
    }

    if (Test-Path -LiteralPath $uninstallKey) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$targetInfo.appVersion)) {
                Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value ([string]$targetInfo.appVersion) -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "Update succeeded, but Windows Apps & Features version could not be refreshed: $($_.Exception.Message)"
        }
    }

    Register-UninstallWrapper

    Set-Content -LiteralPath $successMarker -Value $manifest.toTag -Encoding ASCII
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

if ($env:CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART -eq "1") {
    Write-Host "Application restart skipped by test environment."
}
else {
    Start-Process -FilePath $appExe
}
