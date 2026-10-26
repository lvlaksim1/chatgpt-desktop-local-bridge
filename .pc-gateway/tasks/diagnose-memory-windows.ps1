[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
function MB([double]$x) { [math]::Round($x/1MB,0) }
$result=[ordered]@{status='diagnostic';error='';timestamp=[DateTime]::UtcNow.ToString('o');pagefiles=@();processes=@();warnings=@()}
try {
 $os=Get-CimInstance Win32_OperatingSystem
 $computer=Get-CimInstance Win32_ComputerSystem
 $result.ram_total_MB=[math]::Round([double]$os.TotalVisibleMemorySize/1024,0)
 $result.ram_free_MB=[math]::Round([double]$os.FreePhysicalMemory/1024,0)
 $result.virtual_total_MB=[math]::Round([double]$os.TotalVirtualMemorySize/1024,0)
 $result.virtual_free_MB=[math]::Round([double]$os.FreeVirtualMemory/1024,0)
 $result.auto_pagefile=[bool]$computer.AutomaticManagedPagefile
 $usage=@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
 $result.pagefiles=@($usage|ForEach-Object{"$($_.Name): allocated_MB=$($_.AllocatedBaseSize) current_MB=$($_.CurrentUsage) peak_MB=$($_.PeakUsage)"})
 try {
   $counter=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
   $result.commit_total_MB=MB([double]$counter.CommitLimit)
   $result.commit_used_MB=MB([double]$counter.CommittedBytes)
   $result.available_MB=MB([double]$counter.AvailableBytes)
 } catch {$result.warnings+=("Commit statistics unavailable: "+$_.Exception.Message)}
 try {
    $proc=@(Get-CimInstance Win32_Process | Sort-Object -Property WorkingSetSize -Descending | Select-Object -First 8)
    $result.processes=@($proc|ForEach-Object{ "{0}:{1}MB" -f $_.Name,(MB([double]$_.WorkingSetSize)) })
 } catch {$result.warnings+=("Process memory statistics unavailable: "+$_.Exception.Message)}
 $path='D:\LocalAI\Ollama\logs\server.stderr.log'
 if(Test-Path $path){
   $related=@(Get-Content -LiteralPath $path -Tail 2000 | Where-Object{$_ -match '(?i)(failed to allocate buffer of size|cudaMalloc failed|system memory|free_swap|llama-server terminated|Load failed)'} | Select-Object -Last 12)
   $result.log_error_lines=@($related|ForEach-Object { if($_.Length -gt 300){$_.Substring(0,300)}else{$_} })
 }
 $result.error=("RAM free=$($result.ram_free_MB)/$($result.ram_total_MB) MB; virtual free=$($result.virtual_free_MB)/$($result.virtual_total_MB) MB; commit=$($result.commit_used_MB)/$($result.commit_total_MB) MB; auto_pagefile=$($result.auto_pagefile); pagefiles="+($result.pagefiles -join ';')+"; top="+($result.processes -join ', '))
 if($result.error.Length -gt 695) {$result.error=$result.error.Substring(0,695)}
 $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath 'D:\LocalAI\Ollama\logs\windows-memory-result.json' -Encoding UTF8
 $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
 exit 0
}catch {
 $result.status='failed'
 $result.error=[string]$_.Exception.Message
 $result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
 exit 1
}
