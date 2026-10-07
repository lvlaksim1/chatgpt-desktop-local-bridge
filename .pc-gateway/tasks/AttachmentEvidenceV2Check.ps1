[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$target=Join-Path $PSScriptRoot 'Read-AttachmentProbeEvidenceV2.ps1'
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$errors)|Out-Null
if(@($errors).Count -gt 0){@{status='fail';exit_code=1;error=(@($errors)|ForEach-Object{$_.Message}) -join '; '}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8;exit 1}
@{status='pass';exit_code=0;error=''}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
