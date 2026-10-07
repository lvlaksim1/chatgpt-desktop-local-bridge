[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$script=Join-Path $PSScriptRoot 'Read-AttachmentProbeEvidenceV2.ps1'
& $script -GatewayRequestPath $GatewayRequestPath -GatewayResultPath $GatewayResultPath
exit $LASTEXITCODE
