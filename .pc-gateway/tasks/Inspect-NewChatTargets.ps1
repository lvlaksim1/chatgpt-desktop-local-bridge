[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ProcessName='ChatGptDesktopLocalBridge'
$AppExe=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$OldArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0

function Finish([string]$Status,[int]$Code,[string]$ErrorText=''){
 $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code}
 $d=Split-Path -Parent $GatewayResultPath
 if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
 $p|ConvertTo-Json|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
 Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Compress))
 exit $Code
}
function Stop-App{
 Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
 Start-Sleep -Seconds 1
}
function Wait-App([int]$Seconds=40){
 $d=[DateTime]::UtcNow.AddSeconds($Seconds)
 while([DateTime]::UtcNow -lt $d){
  $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
  if($p.Count -gt 0){return $p[0]}
  Start-Sleep -Milliseconds 500
 }
 return $null
}
function Invoke-Button($Root,[string]$Name){
 $c=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
 $b=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$c)
 if($null-eq$b){throw 'button-not-found'}
 $p=$null
 if(-not$b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$p)){throw 'button-not-invokable'}
 ([System.Windows.Automation.InvokePattern]$p).Invoke()
}
try{
 if(-not(Test-Path -LiteralPath $AppExe)){throw 'installed-app-missing'}
 $port=Get-Random -Minimum 9400 -Maximum 9999
 Stop-App
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
 Start-Process -FilePath $AppExe|Out-Null
 $app=Wait-App
 if($null-eq$app){throw 'window-timeout'}
 Add-Type -AssemblyName UIAutomationClient
 Add-Type -AssemblyName UIAutomationTypes
 $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
 Start-Sleep -Seconds 4
 $before=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/json') -UseBasicParsing -TimeoutSec 3)
 $known=@($before|ForEach-Object{[string]$_.id})
 $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('KyDQp9Cw0YI='))
 Invoke-Button $root $name
 Start-Sleep -Seconds 8
 $after=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$port+'/json') -UseBasicParsing -TimeoutSec 3)
 $new=@($after|Where-Object{-not($known -contains [string]$_.id)})
 $rows=@()
 foreach($t in $new){
  $rows+=('id='+[string]$t.id+';type='+[string]$t.type+';url='+[string]$t.url+';ws='+[string]$t.webSocketDebuggerUrl)
 }
 $text=[string]($rows -join ' || ')
 if($text.Length -gt 1500){$text=$text.Substring(0,1500)}
 Finish 'pass' 0 $text
}catch{
 Finish 'fail' 31 (([string]$_.Exception.Message)+' line='+([string]$_.InvocationInfo.ScriptLineNumber))
}finally{
 Stop-App
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldArgs,'Process')
 if($WasRunning -and (Test-Path -LiteralPath $AppExe)){try{Start-Process -FilePath $AppExe|Out-Null}catch{}}
}
