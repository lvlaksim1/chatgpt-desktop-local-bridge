[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$GapMs=5000
$Root=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$Exe=Join-Path $Root 'ChatGptDesktopLocalBridge.exe'
$Old=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$script:Socket=$null; $script:Id=1; $script:LastCompleted=[DateTime]::MinValue
function Finish([string]$Status,[int]$Code,[string]$ErrorText,[hashtable]$Extra){
  $o=[ordered]@{status=$Status;exit_code=$Code;error=$ErrorText;network_min_gap_ms=$GapMs}
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $o|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit $Code
}
function Stop-All{
  Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
  $needle='ChatGptDesktopLocalBridge\WebView2'
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
    try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
  }
  Start-Sleep -Seconds 1
}
function Wait-App{
  $end=[DateTime]::UtcNow.AddSeconds(45)
  while([DateTime]::UtcNow -lt $end){
    $p=@(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
    if($p.Count){return $true}
    Start-Sleep -Milliseconds 500
  }
  return $false
}
function Wait-Ws([int]$Port){
  $end=[DateTime]::UtcNow.AddSeconds(60)
  while([DateTime]::UtcNow -lt $end){
    try{
      $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
      $t=@($items|Where-Object{$_.type -eq 'page' -and ([string]$_.url) -like 'https://chatgpt.com/*' -and -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)}|Select-Object -First 1)
      if($t.Count){return [string]$t[0].webSocketDebuggerUrl}
    }catch{}
    Start-Sleep -Milliseconds $GapMs
  }
  return ''
}
function Cdp([string]$Method,[hashtable]$Params){
  if($script:LastCompleted -ne [DateTime]::MinValue){
    $elapsed=([DateTime]::UtcNow-$script:LastCompleted).TotalMilliseconds
    if($elapsed -lt $GapMs){Start-Sleep -Milliseconds ([int]($GapMs-$elapsed))}
  }
  $id=$script:Id; $script:Id++
  $json=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $seg=New-Object ArraySegment[byte] -ArgumentList (, $bytes)
  $cts=New-Object Threading.CancellationTokenSource
  $cts.CancelAfter(180000)
  try{
    [void]($script:Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
    while($true){
      $ms=New-Object IO.MemoryStream
      try{
        do{
          $buf=New-Object byte[] 65536
          $bseg=New-Object ArraySegment[byte] -ArgumentList (, $buf)
          $rx=$script:Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
          if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'cdp_closed'}
          $ms.Write($buf,0,$rx.Count)
        }while(-not $rx.EndOfMessage)
        $m=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
        if($null -ne $m.PSObject.Properties['id'] -and [int]$m.id -eq $id){return $m}
      }finally{$ms.Dispose()}
    }
  }finally{$script:LastCompleted=[DateTime]::UtcNow;$cts.Dispose()}
}
function Eval([string]$Expression){
  $r=Cdp 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true}
  if($null -ne $r.PSObject.Properties['error']){throw('cdp_error:'+($r.error|ConvertTo-Json -Compress))}
  if($null -ne $r.result.PSObject.Properties['exceptionDetails']){throw('js_exception:'+($r.result.exceptionDetails|ConvertTo-Json -Depth 6 -Compress))}
  return $r.result.result.value
}
try{
  if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw 'installed_app_missing'}
  Stop-All
  $port=Get-Random -Minimum 9400 -Maximum 9999
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
  Start-Process -FilePath $Exe|Out-Null
  if(-not(Wait-App)){throw 'app_window_missing'}
  $ws=Wait-Ws $port
  if([string]::IsNullOrWhiteSpace($ws)){throw 'cdp_target_missing'}
  $script:Socket=New-Object Net.WebSockets.ClientWebSocket
  $script:Socket.Options.Proxy=$null
  $script:Socket.ConnectAsync([Uri]$ws,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Start-Sleep -Seconds 20

  [void](Cdp 'Accessibility.enable' @{})
  $tree=Cdp 'Accessibility.getFullAXTree' @{}
  if($null -ne $tree.PSObject.Properties['error']){throw('ax_tree_error:'+($tree.error|ConvertTo-Json -Compress))}
  $matches=@()
  foreach($n in @($tree.result.nodes)){
    $name=''; if($null -ne $n.name -and $null -ne $n.name.value){$name=[string]$n.name.value}
    if($name -match '(?i)заплан|scheduled'){
      $role=''; if($null -ne $n.role -and $null -ne $n.role.value){$role=[string]$n.role.value}
      $backend=0; if($null -ne $n.backendDOMNodeId){$backend=[int]$n.backendDOMNodeId}
      $matches += [ordered]@{name=$name;role=$role;backendDOMNodeId=$backend;ignored=[bool]$n.ignored}
    }
  }
  if($matches.Count -eq 0){
    $body=Eval "({url:location.href,title:document.title,body:String(document.body&&document.body.innerText||'').slice(0,2200)})"
    Finish 'evidence' 7 (([ordered]@{stage='ax_scheduled_not_found';ax_matches=$matches;page=$body}|ConvertTo-Json -Depth 8 -Compress)) @{}
  }
  $candidate=@($matches|Where-Object{$_.backendDOMNodeId -gt 0 -and $_.role -match '(?i)link|button|menuitem'}|Select-Object -First 1)
  if($candidate.Count -eq 0){$candidate=@($matches|Where-Object{$_.backendDOMNodeId -gt 0}|Select-Object -First 1)}
  if($candidate.Count -eq 0){Finish 'evidence' 7 (([ordered]@{stage='ax_match_without_dom';ax_matches=$matches}|ConvertTo-Json -Depth 8 -Compress)) @{}}
  $backend=[int]$candidate[0].backendDOMNodeId
  $box=Cdp 'DOM.getBoxModel' @{backendNodeId=$backend}
  if($null -ne $box.PSObject.Properties['error']){Finish 'evidence' 7 (([ordered]@{stage='box_model_failed';candidate=$candidate[0];error=$box.error}|ConvertTo-Json -Depth 8 -Compress)) @{}}
  $quad=@($box.result.model.content)
  if($quad.Count -lt 8){throw 'invalid_box_model'}
  $x=(([double]$quad[0]+[double]$quad[2]+[double]$quad[4]+[double]$quad[6])/4.0)
  $y=(([double]$quad[1]+[double]$quad[3]+[double]$quad[5]+[double]$quad[7])/4.0)
  [void](Cdp 'Input.dispatchMouseEvent' @{type='mousePressed';x=$x;y=$y;button='left';clickCount=1})
  [void](Cdp 'Input.dispatchMouseEvent' @{type='mouseReleased';x=$x;y=$y;button='left';clickCount=1})
  Start-Sleep -Seconds 15
  $obs=Eval @'
(()=>({
 url:location.href,title:document.title,ready:document.readyState,
 file_inputs:Array.from(document.querySelectorAll('input[type="file"]')).map((e,i)=>({i,accept:e.accept||null,multiple:!!e.multiple,aria:e.getAttribute('aria-label'),testid:e.getAttribute('data-testid')})),
 controls:Array.from(document.querySelectorAll('button,a,[role="button"],[role="link"]')).map((e,i)=>({i,tag:e.tagName,text:String(e.innerText||e.textContent||'').trim().slice(0,120),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),testid:e.getAttribute('data-testid'),href:String(e.href||'')})).filter(x=>/attach|upload|file|прикреп|файл|task|automation|заплан|edit|измен/i.test([x.text,x.aria,x.title,x.testid,x.href].filter(Boolean).join(' '))).slice(0,100),
 body:String(document.body&&document.body.innerText||'').slice(0,6000)
}))()
'@
  Finish 'evidence' 7 (([ordered]@{stage='ax_clicked';candidate=$candidate[0];click=[ordered]@{x=$x;y=$y};observation=$obs}|ConvertTo-Json -Depth 10 -Compress)) @{}
}catch{Finish 'fail' 40 $_.Exception.Message @{}}
finally{
  if($null -ne $script:Socket){try{$script:Socket.Dispose()}catch{}}
  try{Stop-All}catch{}
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$Old,'Process')
}
