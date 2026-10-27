param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$r=[ordered]@{status='failed';error='';syntax='failed';lines=0}
try{
 $target=Join-Path $PSScriptRoot 'repair-goose-ru-native.ps1'
 $tokens=$null;$parseErrors=$null
 $ast=[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$parseErrors)
 $r.lines=@(Get-Content -LiteralPath $target).Count
 if(@($parseErrors).Count -ne 0){
  $r.error=@($parseErrors|Select-Object -First 3|ForEach-Object{$_.Message+' at line '+$_.Extent.StartLineNumber}) -join '; '
 }else{$r.status='success';$r.syntax='success';$r.error='PowerShell syntax validated'}
}catch{$r.error=[string]$_.Exception.Message}
$r|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
