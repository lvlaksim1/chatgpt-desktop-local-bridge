[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Result {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorText = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        status = $Status
        exit_code = $ExitCode
        error = $ErrorText
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $directory = Split-Path -Parent $GatewayResultPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $payload | ConvertTo-Json -Depth 16 |
        Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

$tag = 'direct-bridge-test-6ab0c4d'
$asset = 'ChatGptDesktopLocalBridge-TerminalProbe.zip'
$expectedSha256 = '7656fb0d22ecb3d05b74bca3e5ba79211c15727b1c39483d2e2fb18b1e4c726b'
$url = "https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/$tag/$asset"

$work = Join-Path $env:TEMP ('direct-bridge-prebuilt-' + [Guid]::NewGuid().ToString('N'))
$zip = Join-Path $work $asset
$unpack = Join-Path $work 'probe'
$stdoutPath = Join-Path $work 'stdout.txt'
$stderrPath = Join-Path $work 'stderr.txt'

New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

    $actualSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        Write-Result -Status 'fail' -ExitCode 41 -ErrorText ("SHA256 mismatch: " + $actualSha256)
    }

    Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force

    $probeExe = Join-Path $unpack 'ChatGptDesktopLocalBridge.TerminalTests.exe'
    if (-not (Test-Path -LiteralPath $probeExe -PathType Leaf)) {
        $candidate = Get-ChildItem -LiteralPath $unpack -Recurse -Filter '*.exe' -File |
            Where-Object { $_.Name -like '*TerminalTests*.exe' } |
            Select-Object -First 1
        if ($null -eq $candidate) {
            Write-Result -Status 'fail' -ExitCode 42 -ErrorText 'Self-contained terminal probe executable not found.'
        }
        $probeExe = $candidate.FullName
    }

    $process = Start-Process -FilePath $probeExe -WorkingDirectory $unpack -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        [string](Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8)
    } else { '' }

    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        [string](Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8)
    } else { '' }

    if ($process.ExitCode -ne 0) {
        Write-Result -Status 'fail' -ExitCode 43 -ErrorText ("Probe exit code " + $process.ExitCode + '.') -Extra @{
            stdout = $stdout
            stderr = $stderr
            package_sha256 = $actualSha256
        }
    }

    if ($stdout -notmatch 'PASS persistent-terminal') {
        Write-Result -Status 'fail' -ExitCode 44 -ErrorText 'PASS marker was not emitted.' -Extra @{
            stdout = $stdout
            stderr = $stderr
            package_sha256 = $actualSha256
        }
    }

    Write-Result -Status 'pass' -ExitCode 0 -Extra @{
        package_tag = $tag
        package_sha256 = $actualSha256
        stdout = $stdout.Trim()
        stderr = $stderr.Trim()
    }
}
catch {
    Write-Result -Status 'fail' -ExitCode 45 -ErrorText $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
