[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$Gap=5
$Root=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$Exe=Join-Path $Root 'ChatGptDesktopLocalBridge.exe'
$Old=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$script:Socket=$null; $script:Id=1
function Finish([string]$s,[int]$c,[string]$e,[hashtable]$x){$o=[ordered]@{status=$s;exit_code=$c;error=$e;network_min_gap_seconds=$Gap};foreach($k in $x.Keys){$o[$k]=$x[$k]};$d=Split-Path -Parent $GatewayResultPath;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null};$o|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8;exit $c}
function Stop-All{Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue;$needle='ChatGptDesktopLocalBridge\WebView2';foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}};Start-Sleep -Seconds 1}
function Wait-App{$end=[DateTime]::UtcNow.AddSeconds(45);while([DateTime]::UtcNow -lt $end){$p=@(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1);if($p.Count){return $true};Start-Sleep -Milliseconds 500};return $false}
function Wait-Ws([int]$Port){$end=[DateTime]::UtcNow.AddSeconds(60);while([DateTime]::UtcNow -lt $end){try{$raw=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2;$arr=@($raw);$candidate=@($arr|Where-Object{$_.type -eq 'page' -and ([string]$_.url) -like 'https://chatgpt.com/*' -and -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)}|Select-Object -First 1);if($candidate.Count -gt 0){$one=$candidate[0];return ([string]$one.webSocketDebuggerUrl)}}catch{};Start-Sleep -Seconds $Gap};return ''}
function Cdp([string]$m,[hashtable]$p){$id=$script:Id;$script:Id++;$j=@{id=$id;method=$m;params=$p}|ConvertTo-Json -Depth 20 -Compress;$b=[Text.Encoding]::UTF8.GetBytes($j);$sg=New-Object ArraySegment[byte] -ArgumentList (, $b);$cts=New-Object Threading.CancellationTokenSource;$cts.CancelAfter(180000);try{[void]($script:Socket.SendAsync($sg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult());while($true){$ms=New-Object IO.MemoryStream;try{do{$buf=New-Object byte[] 65536;$bs=New-Object ArraySegment[byte] -ArgumentList (, $buf);$r=$script:Socket.ReceiveAsync($bs,$cts.Token).GetAwaiter().GetResult();if($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'cdp_closed'};$ms.Write($buf,0,$r.Count)}while(-not $r.EndOfMessage);$o=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json);if($null -ne $o.PSObject.Properties['id'] -and [int]$o.id -eq $id){return $o}}finally{$ms.Dispose()}}}finally{$cts.Dispose()}}
function Eval([string]$x){$r=Cdp 'Runtime.evaluate' @{expression=$x;returnByValue=$true;awaitPromise=$true};if($null -ne $r.PSObject.Properties['error']){throw('cdp_error:'+($r.error|ConvertTo-Json -Compress))};if($null -ne $r.result.PSObject.Properties['exceptionDetails']){throw('js_exception:'+($r.result.exceptionDetails|ConvertTo-Json -Depth 6 -Compress))};return $r.result.result.value}
try{
 if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw 'installed_app_missing'}
 Stop-All
 $port=Get-Random -Minimum 9400 -Maximum 9999
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
 Start-Process -FilePath $Exe|Out-Null
 if(-not(Wait-App)){throw 'app_window_missing'}
 $ws=Wait-Ws $port
 if([string]::IsNullOrWhiteSpace($ws)){throw 'cdp_target_missing'}
 Write-Host ('CDP_WS='+$ws)
 $script:Socket=New-Object Net.WebSockets.ClientWebSocket
 $script:Socket.Options.Proxy=$null
 try{$script:Socket.ConnectAsync([Uri]$ws,[Threading.CancellationToken]::None).GetAwaiter().GetResult()}catch{throw('cdp_connect_failed:'+ $_.Exception.Message)}
 Start-Sleep -Seconds $Gap
 $before=Eval "({url:location.href,title:document.title,ready:document.readyState})"
 Start-Sleep -Seconds $Gap
 $nav=Eval @'
(()=>{
 const all=Array.from(document.querySelectorAll('*'));
 const label=all.find(e=>String(e.textContent||'').trim()==='Запланировано');
 if(!label) return {clicked:false,reason:'label_not_found',url:location.href};
 const clickable=label.closest('a,button,[role="link"],[role="button"]') || label.parentElement || label;
 const info={clicked:true,text:String(label.textContent||'').trim(),href:String(clickable.href||''),tag:clickable.tagName,role:String(clickable.getAttribute&&clickable.getAttribute('role')||'')};
 clickable.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
 return info;
})()
'@
 if(-not [bool]$nav.clicked){throw ('scheduled_navigation_control_not_found:'+ [string]$nav.reason)}
 Start-Sleep -Seconds 15
 $obs=Eval @'
(()=>{const f=Array.from(document.querySelectorAll('input[type="file"]')).map((e,i)=>({i,accept:e.accept||null,multiple:!!e.multiple,aria:e.getAttribute('aria-label'),testid:e.getAttribute('data-testid')}));const b=Array.from(document.querySelectorAll('button')).slice(0,400).map((e,i)=>({i,text:String(e.innerText||'').trim().slice(0,140),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),testid:e.getAttribute('data-testid')}));const a=Array.from(document.querySelectorAll('a')).slice(0,400).map((e,i)=>({i,text:String(e.innerText||'').trim().slice(0,140),href:e.href||null,aria:e.getAttribute('aria-label')}));return{url:location.href,title:document.title,ready:document.readyState,file_inputs:f,buttons:b,links:a,body_text:String(document.body&&document.body.innerText||'').slice(0,20000)}})()
'@
 Write-Host ('ATTACH_UI_OBSERVATION='+($obs|ConvertTo-Json -Depth 10 -Compress))
 Finish 'pass' 0 '' @{before=$before;navigation=$nav;observation=$obs;cdp_ws=$ws}
}catch{Finish 'fail' 40 $_.Exception.Message @{}}
finally{if($null -ne $script:Socket){try{$script:Socket.Dispose()}catch{}};try{Stop-All}catch{};[Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$Old,'Process')}
