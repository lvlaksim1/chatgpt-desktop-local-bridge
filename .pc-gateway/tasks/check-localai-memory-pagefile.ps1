[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$report=[ordered]@{status='diagnostic';error='';utc=[DateTime]::UtcNow.ToString('o');pagefiles=@();auto_pagefile=$null;commit_used_mb=$null;commit_limit_mb=$null;physical_free_mb=$null;physical_total_mb=$null;api_running=$false;notes=@()}
try {
 $p=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
 $report.pagefiles=@($p.PagingFiles | ForEach-Object{[string]$_})
} catch { $report.notes+=('Registry paging config: '+$_.Exception.Message) }
try{
 Add-Type -AssemblyName Microsoft.VisualBasic
 $ci=New-Object Microsoft.VisualBasic.Devices.ComputerInfo
 $report.physical_free_mb=[math]::Round([double]$ci.AvailablePhysicalMemory/1MB,0)
 $report.physical_total_mb=[math]::Round([double]$ci.TotalPhysicalMemory/1MB,0)
}catch{$report.notes+=('Physical memory: '+$_.Exception.Message)}
foreach($name in @('Committed Bytes','Commit Limit')){
 try{
  $counter=New-Object System.Diagnostics.PerformanceCounter('Memory',$name)
  $value=[math]::Round([double]$counter.NextValue()/1MB,0)
  $counter.Dispose()
  if($name -eq 'Committed Bytes'){$report.commit_used_mb=$value}else{$report.commit_limit_mb=$value}
 }catch{$report.notes+=($name+': '+$_.Exception.Message)}
}
try{
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 3
 $report.api_running=$true
}catch{}
$report.error='pagefiles='+($report.pagefiles -join '; ')+'; commit_used_mb='+$report.commit_used_mb+'; commit_limit_mb='+$report.commit_limit_mb+'; physical_free_mb='+$report.physical_free_mb+'; physical_total_mb='+$report.physical_total_mb+'; ollama_api='+$report.api_running+'; notes='+($report.notes -join ' | ')
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
$logs='D:\LocalAI\Ollama\logs'
if(Test-Path $logs){$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $logs 'memory-pagefile-diagnostic.json') -Encoding UTF8}
exit 0
