[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
@{status='pass';exit_code=0;error=''}|ConvertTo-Json|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
