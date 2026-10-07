[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$relative=[string]$request.args.target_script
$root=Split-Path -Parent $PSScriptRoot
$repoRoot=Split-Path -Parent $root
$target=Join-Path $repoRoot $relative

$tokens=$null
$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $target,
    [ref]$tokens,
    [ref]$errors)

$rows=@($errors|ForEach-Object{
    [ordered]@{
        message=$_.Message
        line=$_.Extent.StartLineNumber
        column=$_.Extent.StartColumnNumber
        text=$_.Extent.Text
    }
})

$payload=[ordered]@{
    status=$(if($rows.Count -eq 0){'pass'}else{'evidence'})
    error=$(if($rows.Count -eq 0){''}else{($rows|ConvertTo-Json -Compress -Depth 10)})
    exit_code=$(if($rows.Count -eq 0){0}else{20})
    target_script=$relative
    parse_error_count=$rows.Count
}
$dir=Split-Path -Parent $GatewayResultPath
if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
$payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 12 -Compress))
exit [int]$payload.exit_code
