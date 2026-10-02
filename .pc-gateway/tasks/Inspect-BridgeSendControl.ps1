[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$TargetTag='dev-0835894'
$TargetCommit='08358945143328f990fdf2e13ed64a387b67a900'
$Marker='LOCAL-BRIDGE-SUBMIT-DIAG-20261002'
$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfo=Join-Path $InstallRoot 'release-info.json'
$ProcessName='ChatGptDesktopLocalBridge'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket=$null
$Stage='start'

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
  $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage;target_tag=$TargetTag;target_commit=$TargetCommit}
  foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $p|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 12 -Compress))
  exit $Code
}
function Stop-App {
  foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
    try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
  }
  Start-Sleep -Seconds 2
  Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
  $needle='ChatGptDesktopLocalBridge\WebView2'
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
    try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
  }
}
function Wait-App([int]$TimeoutSeconds=30){
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline){
    $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
    if($p.Count -gt 0){return $p[0]}
    Start-Sleep -Milliseconds 250
  }
  return $null
}
function Wait-Target([int]$Port,[int]$TimeoutSeconds=30){
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline){
    try{
      $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
      $t=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
      if($t.Count -gt 0){return $t[0]}
    }catch{}
    Start-Sleep -Milliseconds 250
  }
  return $null
}
function Send-Cdp($Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{}){
  $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
  $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
  $cts=New-Object Threading.CancellationTokenSource
  $cts.CancelAfter(10000)
  try{
    [void]$Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
    while($true){
      $ms=New-Object IO.MemoryStream
      try{
        do{
          $buf=New-Object byte[] 65536
          $rxseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
          $rx=$Socket.ReceiveAsync($rxseg,$cts.Token).GetAwaiter().GetResult()
          if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP socket closed.'}
          $ms.Write($buf,0,$rx.Count)
        }while(-not $rx.EndOfMessage)
        $msg=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
        if($null-ne$msg.PSObject.Properties['id'] -and [int]$msg.id -eq $Id){return $msg}
      }finally{$ms.Dispose()}
    }
  }finally{$cts.Dispose()}
}
function Eval($Socket,[ref]$Id,[string]$Expression){
  $r=Send-Cdp $Socket $Id.Value 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true}
  $Id.Value++
  if($null-ne$r.PSObject.Properties['error']){throw ('CDP error: '+($r.error|ConvertTo-Json -Compress))}
  return $r.result.result.value
}
function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=30){
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline){
    $h=Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
    if($null-ne$h -and [int]$h.version -ge 9 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return $h}
    Start-Sleep -Milliseconds 250
  }
  throw 'Adapter v9+ did not become ready.'
}
function Clear-KnownSafeDraft($Socket,[ref]$Id){
  $classification=Eval $Socket $Id @'
(() => {
  const selectors=["#prompt-textarea","textarea[data-testid='prompt-textarea']","div[contenteditable='true'][data-testid='prompt-textarea']","div[contenteditable='true'][role='textbox']"];
  let n=null;for(const s of selectors){n=document.querySelector(s);if(n)break;}
  if(!n)return {composerFound:false,empty:true,recognized:false,kind:"none"};
  const text=(n.innerText||n.value||n.textContent||"").trim();
  if(!text)return {composerFound:true,empty:true,recognized:false,kind:"empty"};
  const bridgeOwned=text.startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||text.startsWith("[[LOCAL_BRIDGE_RESULT_V1]]");
  const knownProbe=text.startsWith("Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose.")&&text.includes("req-m3-live-final")&&text.includes("C:/Windows/win.ini");
  const ownDiag=text==="LOCAL-BRIDGE-SUBMIT-DIAG-20261002";
  const recognized=bridgeOwned||knownProbe||ownDiag;
  if(recognized){
    n.focus();
    if(typeof n.select==="function"){n.select();}
    else{
      const sel=window.getSelection();if(!sel)return {composerFound:true,empty:false,recognized:false,kind:"selection-unavailable"};
      const r=document.createRange();r.selectNodeContents(n);sel.removeAllRanges();sel.addRange(r);
    }
  }
  return {composerFound:true,empty:false,recognized,kind:bridgeOwned?"bridge-envelope":knownProbe?"m3-probe":ownDiag?"send-control-diag":"unrecognized"};
})()
'@
  if([bool]$classification.empty){return $classification}
  if(-not [bool]$classification.recognized){
    throw ('Composer contains an unrecognized draft; diagnostic left it untouched. kind='+[string]$classification.kind)
  }
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
    if($null-ne$state -and [bool]$state.composerEmpty){return $classification}
    Start-Sleep -Milliseconds 100
  }
  throw 'Recognized stale diagnostic/bridge draft did not clear.'
}

function Clear-ExactMarker($Socket,[ref]$Id){
  $expected=$Marker|ConvertTo-Json -Compress
  $selected=[bool](Eval $Socket $Id @"
(() => {
  const selectors=["#prompt-textarea","textarea[data-testid='prompt-textarea']","div[contenteditable='true'][data-testid='prompt-textarea']","div[contenteditable='true'][role='textbox']"];
  let n=null; for(const s of selectors){n=document.querySelector(s);if(n)break;} if(!n)return false;
  const text=(n.innerText||n.value||n.textContent||"").trim();
  if(text!==$expected)return false;
  n.focus();
  if(typeof n.select==="function"){n.select();return true;}
  const sel=window.getSelection();if(!sel)return false;const r=document.createRange();r.selectNodeContents(n);sel.removeAllRanges();sel.addRange(r);return true;
})()
"@)
  if(-not $selected){return}
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
}

$port=Get-Random -Minimum 9400 -Maximum 9999
try{
  $Stage='verify-release'
  $rel=Get-Content -LiteralPath $ReleaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$rel.tag -ne $TargetTag -or [string]$rel.commit -ne $TargetCommit){throw "Installed release mismatch: '$($rel.tag)' '$($rel.commit)'."}

  $Stage='start-app'
  Stop-App
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
  Start-Process -FilePath $AppExe|Out-Null
  if($null-eq(Wait-App 30)){throw 'Application window did not appear.'}

  $Stage='connect-cdp'
  $target=Wait-Target $port 30
  if($null-eq$target){throw 'CDP target unavailable.'}
  $Socket=New-Object Net.WebSockets.ClientWebSocket
  $connectCts=New-Object Threading.CancellationTokenSource
  $connectCts.CancelAfter(10000)
  try{
    try{$Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,$connectCts.Token).GetAwaiter().GetResult()}
    catch{if($connectCts.IsCancellationRequested){throw 'CDP websocket connect timed out after 10 seconds.'};throw}
  }finally{$connectCts.Dispose()}
  $id=1

  $Stage='prepare'
  [void](Send-Cdp $Socket $id 'Page.navigate' @{url='https://chatgpt.com/'});$id++
  $health=Wait-Adapter $Socket ([ref]$id) 30
  $cleared=Clear-KnownSafeDraft $Socket ([ref]$id)

  $Stage='insert-marker'
  $prepare=Eval $Socket ([ref]$id) 'window.__localBridge.prepareNativeSend()'
  if(-not [bool]$prepare.accepted){throw ('Adapter preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
  [void](Send-Cdp $Socket $id 'Input.insertText' @{text=$Marker});$id++

  $expected=$Marker|ConvertTo-Json -Compress
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  $inserted=$false
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket ([ref]$id) ('window.__localBridge.nativeSendState('+$expected+')')
    if([bool]$state.textMatches){$inserted=$true;break}
    Start-Sleep -Milliseconds 100
  }
  if(-not $inserted){throw 'Diagnostic marker was not accepted by native input.'}

  $Stage='inspect-controls'
  $controls=Eval $Socket ([ref]$id) @'
(() => {
  const composer=document.querySelector("#prompt-textarea,textarea[data-testid='prompt-textarea'],div[contenteditable='true'][data-testid='prompt-textarea'],div[contenteditable='true'][role='textbox']");
  const form=composer?.closest("form")||null;
  if(!composer||!form)return {formFound:Boolean(form),buttons:[],known:{}};
  const visible=n=>{const r=n.getBoundingClientRect();const s=getComputedStyle(n);return r.width>0&&r.height>0&&s.display!=="none"&&s.visibility!=="hidden";};
  const buttons=Array.from(form.querySelectorAll("button")).map((b,index)=>({
    index,
    testId:b.getAttribute("data-testid"),
    ariaLabel:b.getAttribute("aria-label"),
    type:b.getAttribute("type"),
    title:b.getAttribute("title"),
    disabled:Boolean(b.disabled),
    visible:visible(b)
  }));
  const selectors=["button[data-testid='send-button']","#composer-submit-button","button[type='submit']"];
  const known={};
  for(const s of selectors){const n=form.querySelector(s);known[s]=n?{disabled:Boolean(n.disabled),visible:visible(n),ariaLabel:n.getAttribute("aria-label"),testId:n.getAttribute("data-testid"),type:n.getAttribute("type")}:null;}
  return {formFound:true,buttons,known};
})()
'@

  $Stage='pass'
  Finish 'pass' 0 '' @{
    adapter_version=[int]$health.version
    form_found=[bool]$controls.formFound
    buttons=$controls.buttons
    known_controls=$controls.known
    cleared_stale_kind=[string]$cleared.kind
  }
}catch{
  Finish 'fail' 31 $_.Exception.Message
}finally{
  if($null-ne$Socket){try{Clear-ExactMarker $Socket ([ref]$id)}catch{};try{$Socket.Dispose()}catch{}}
  try{Stop-App}catch{}
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
  if($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){try{Start-Process -FilePath $AppExe|Out-Null}catch{}}
}
