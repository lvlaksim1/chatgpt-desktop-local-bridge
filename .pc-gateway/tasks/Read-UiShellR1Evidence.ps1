[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$requestId = 'ui-shell-r1-4c92f81-e2e-01'
$issueNumber = 192
$ledger = Join-Path $env:LOCALAPPDATA ('GitHubRunner\pc-runner-gateway\request-ledger\evidence\' + $requestId)
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
[void]$builder.AppendLine('### PC Runner evidence for ' + $requestId)

foreach ($name in $names) {
    $path = Join-Path $ledger $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

    $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }
    if ($content.Length -gt 5000) {
        $content = $content.Substring(0, 5000) + [Environment]::NewLine + '...[truncated]'
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
    & $gh.Source issue comment $issueNumber --repo lvlaksim1/pc-runner-gateway --body-file $bodyPath
    if ($LASTEXITCODE -ne 0) { throw "gh issue comment failed with exit code $LASTEXITCODE" }

    $payload = [ordered]@{
        status = 'success'
        request_id = $requestId
        evidence_path = $ledger
        issue_number = $issueNumber
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit 0
}
finally {
    Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
}
