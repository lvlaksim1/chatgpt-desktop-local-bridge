param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$p='D:\LocalAI\Goose\logs\goose-ru-header-hash.err'
$report=[ordered]@{status='diagnostic';error='';file_found=$false}
if(Test-Path -LiteralPath $p -PathType Leaf){
 $report.file_found=$true
 $report.error=((Get-Content -LiteralPath $p -First 15|Out-String).Trim() -replace '[\r\n\t]+',' ')
 if($report.error.Length -gt 660){$report.error=$report.error.Substring(0,660)}
}else{$report.error='no stderr file'}
$report|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
