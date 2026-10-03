[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$request = Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetRequestId = [string]$request.args.target_request_id
$targetIssueNumber = [int]$request.args.target_issue_number
if ($targetRequestId -notmatch '^[A-Za-z0-9._-]{1,96}$') { throw 'Unsafe target_request_id.' }
if ($targetIssueNumber -le 0) { throw 'Invalid target_issue_number.' }

$ledger = Join-Path $env:LOCALAPPDATA ('GitHubRunner\pc-runner-gateway\request-ledger\evidence\' + $targetRequestId)
$names = @(
    'result.json',
    'task-result.json',
    'task-stdout.log',
    'task-stderr.log',
    'project-result.json',
    'project-stdout.log',
    'project-stderr.log'
)

$builder = New-Object Text.StringBuilder
[void]$builder.AppendLine('### PC Runner evidence for ' + $targetRequestId)

foreach ($name in $names) {
    $path = Join-Path $ledger $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

    $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }
    if ($content.Length -gt 8000) {
        $content = $content.Substring(0, 8000) + [Environment]::NewLine + '...[truncated]'
    }

    [void]$builder.AppendLine()
    [void]$builder.AppendLine('#### ' + $name)
    [void]$builder.AppendLine('~~~text')
    [void]$builder.AppendLine($content)
    [void]$builder.AppendLine('~~~')
}

$bodyPath = Join-Path $env:TEMP ('pcgw-evidence-' + [Guid]::NewGuid().ToString('N') + '.md')
$builder.ToString() | Set-Content -LiteralPath $bodyPath -Encoding UTF8

try {
    $gh = Get-Command gh.exe -ErrorAction Stop
    & $gh.Source issue comment $targetIssueNumber --repo lvlaksim1/pc-runner-gateway --body-file $bodyPath
    if ($LASTEXITCODE -ne 0) { throw "gh issue comment failed with exit code $LASTEXITCODE" }

    $payload = [ordered]@{
        status = 'success'
        target_request_id = $targetRequestId
        evidence_path = $ledger
        target_issue_number = $targetIssueNumber
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit 0
}
finally {
    Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
}
