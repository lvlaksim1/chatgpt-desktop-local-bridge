[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
& (Join-Path $PSScriptRoot 'Read-AttachmentProbeEvidenceV2.ps1') -GatewayRequestPath $GatewayRequestPath -GatewayResultPath $GatewayResultPath
exit $LASTEXITCODE
