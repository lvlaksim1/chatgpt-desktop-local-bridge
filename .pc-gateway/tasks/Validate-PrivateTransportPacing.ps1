[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$target = Join-Path $PSScriptRoot 'Probe-PrivateTransportE2EPhased.ps1'
if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Target script missing: $target"}

$tokens=$null
$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $target,
    [ref]$tokens,
    [ref]$errors)

$text=Get-Content -LiteralPath $target -Raw -Encoding UTF8
$directFetchCount=([regex]::Matches($text,'await\s+fetch\s*\(')).Count
$subSecondDelayCount=([regex]::Matches($text,'delay\s*\(\s*(?:[0-4]?\d{1,3}|[1-4]\d{3})\s*\)')).Count

$checks=[ordered]@{
    parse_ok = (@($errors).Count -eq 0)
    min_gap_constant = ($text -match 'NETWORK_MIN_GAP_MS\s*=\s*5000')
    serialized_gate_present = ($text -match 'function\s+pacedFetch')
    only_gate_calls_raw_fetch = ($directFetchCount -eq 1)
    no_sub_5000_js_delays = ($subSecondDelayCount -eq 0)
    localhost_probe_gap_5s = ($text -match 'Start-Sleep\s+-Seconds\s+5')
    legacy_page_navigate_absent = ($text -notmatch "Page\.navigate")
}

$pass = -not ($checks.Values -contains $false)
$payload=[ordered]@{
    status = if($pass){'pass'}else{'fail'}
    exit_code = if($pass){0}else{31}
    checks = $checks
    parse_errors = @($errors | ForEach-Object { $_.Message })
    direct_fetch_count = $directFetchCount
    sub_5000_delay_count = $subSecondDelayCount
}

$dir=Split-Path -Parent $GatewayResultPath
if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
$payload|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
Write-Host ('PACING_VALIDATION_RESULT='+($payload|ConvertTo-Json -Depth 10 -Compress))
exit $payload.exit_code
