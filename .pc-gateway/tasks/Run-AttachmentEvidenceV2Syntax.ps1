[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$checker=Join-Path $PSScriptRoot 'Check-Read-AttachmentProbeEvidenceV2.ps1'
& $checker -GatewayRequestPath $GatewayRequestPath -GatewayResultPath $GatewayResultPath
exit $LASTEXITCODE
