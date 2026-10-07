[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$reader=Join-Path $PSScriptRoot 'Read-AttachmentProbeEvidenceV2.ps1'
& $reader -GatewayRequestPath $GatewayRequestPath -GatewayResultPath $GatewayResultPath
exit $LASTEXITCODE
