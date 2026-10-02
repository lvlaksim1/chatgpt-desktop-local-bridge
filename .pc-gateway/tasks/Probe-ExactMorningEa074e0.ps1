[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$MorningCommit='ea074e06bd4e959106f49f57cad1ac731597dac3'
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$PublishRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\benchmark-ea074e0'
$AppExe=Join-Path $PublishRoot 'ChatGptDesktopLocalBridge.exe'
$LogRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$ProcessName='ChatGptDesktopLocalBridge'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$OldTracking=[Environment]::GetEnvironmentVariable('RUNNER_TRACKING_ID','Process')
$Socket=$null
$Stage='start'
$Session=''
$SubmitConfirmed=$false
$TestStarted=[DateTimeOffset]::UtcNow

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
  $p=[ordered]@{
    status=$Status
    error=$ErrorText
    exit_code=$Code
    stage=$Stage
    morning_commit=$MorningCommit
    portable_path=$AppExe
  }
  foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $p|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 16 -Compress))
  exit $Code
}

function Stop-BridgeProcesses {
  Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
  $needle='ChatGptDesktopLocalBridge\WebView2'
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
    try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
  }
  Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds=45){
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline){
    $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
    if($p.Count -gt 0){return $p[0]}
    Start-Sleep -Milliseconds 250
  }
  return $null
}

function Invoke-Button($Root,[string]$Name){
  $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
  $button=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
  if($null-eq$button){throw "UI button '$Name' not found."}
  $pattern=$null
  if(-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw "UI button '$Name' not invokable."}
  ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=45){
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

function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=45){
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline){
    $h=Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
    if($null-ne$h -and [int]$h.version -eq 5 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return $h}
    Start-Sleep -Milliseconds 250
  }
  throw 'Exact morning adapter v5 did not become ready.'
}

function Clear-RecognizedDraft($Socket,[ref]$Id){
  $c=Eval $Socket $Id @'
(() => {
  const n=document.querySelector("#prompt-textarea,textarea[data-testid='prompt-textarea'],div[contenteditable='true'][data-testid='prompt-textarea'],div[contenteditable='true'][role='textbox']");
  if(!n)return {empty:true,recognized:false,kind:"none"};
  const text=(n.innerText||n.value||n.textContent||"").trim();
  if(!text)return {empty:true,recognized:false,kind:"empty"};
  const bridge=text.startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||text.startsWith("[[LOCAL_BRIDGE_RESULT_V1]]");
  const probe=text.startsWith("Use the current Local Bridge session.")&&text.includes("C:/Windows/win.ini");
  const recognized=bridge||probe;
  if(recognized){
    n.focus();
    if(typeof n.select==="function")n.select();
    else{const s=window.getSelection();const r=document.createRange();r.selectNodeContents(n);s.removeAllRanges();s.addRange(r);}
  }
  return {empty:false,recognized,kind:bridge?"bridge-envelope":probe?"fsread-probe":"unrecognized"};
})()
'@
  if([bool]$c.empty){return [string]$c.kind}
  if(-not [bool]$c.recognized){throw 'Composer contains an unrecognized user draft; exact-morning benchmark left it untouched.'}
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  while([DateTime]::UtcNow -lt $deadline){
    $s=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
    if($null-ne$s -and [bool]$s.composerEmpty){return [string]$c.kind}
    Start-Sleep -Milliseconds 100
  }
  throw 'Recognized stale bridge draft did not clear.'
}

function Find-ReadySession($Socket,[ref]$Id){
  return Eval $Socket $Id @'
(() => {
  const nodes=Array.from(document.querySelectorAll("[data-markdown-text-style='assistant-message'],[data-message-author-role='assistant']"));
  for(let i=nodes.length-1;i>=0;i--){
    const t=(nodes[i].innerText||nodes[i].textContent||"").trim();
    const m=t.match(/^\[\[LOCAL_BRIDGE_READY_V1:([a-fA-F0-9]{32})\]\]$/);
    if(m)return {session:m[1],text:t};
  }
  return null;
})()
'@
}

function Send-MorningText($Socket,[ref]$Id,[string]$Text){
  $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
  if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Morning preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
  [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
  $expected=$Text|ConvertTo-Json -Compress
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  $inserted=$false
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
    if($null-ne$state -and [bool]$state.textMatches){$inserted=$true;break}
    Start-Sleep -Milliseconds 100
  }
  if(-not $inserted){throw 'Morning prompt insert was not verified.'}
  $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
  if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Morning submit rejected: '+($submit|ConvertTo-Json -Compress))}
  $deadline=[DateTime]::UtcNow.AddSeconds(12)
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
    if($null-ne$state -and [bool]$state.composerEmpty){return $true}
    Start-Sleep -Milliseconds 100
  }
  return $false
}

function Find-FsReadAudit([string]$Session,[DateTimeOffset]$StartedAfter){
  if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
  foreach($f in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
    foreach($line in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      try{
        $r=$line|ConvertFrom-Json
        $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
        if($ts -ge $StartedAfter -and [string]$r.session -eq $Session -and [string]$r.tool -eq 'fs.read_text'){return $r}
      }catch{}
    }
  }
  return $null
}

function Find-FinalAnswer($Socket,[ref]$Id){
  return Eval $Socket $Id @'
(() => {
  const nodes=Array.from(document.querySelectorAll("[data-markdown-text-style='assistant-message'],[data-message-author-role='assistant']"));
  for(let i=nodes.length-1;i>=0;i--){
    const t=(nodes[i].innerText||nodes[i].textContent||"").trim();
    if(t.includes("MAPI=1") && t.includes("[Mail]")) return t.slice(0,5000);
  }
  return null;
})()
'@
}

$port=Get-Random -Minimum 9400 -Maximum 9999
try{
  $Stage='download-exact-morning'
  if(Test-Path -LiteralPath $PublishRoot){Remove-Item -LiteralPath $PublishRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $PublishRoot|Out-Null
  $zip=Join-Path $env:TEMP ('bridge-ea074e0-'+[Guid]::NewGuid().ToString('N')+'.zip')
  try{
    $url='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/benchmark-ea074e0/ChatGptDesktopLocalBridge-ea074e0-portable.zip'
    $wc=New-Object Net.WebClient
    try{$wc.DownloadFile($url,$zip)}finally{$wc.Dispose()}
    Expand-Archive -LiteralPath $zip -DestinationPath $PublishRoot -Force
  }finally{
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  }
  if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'Morning portable executable was not downloaded/extracted.'}

  $Stage='launch-exact-morning'
  Stop-BridgeProcesses
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
  [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID','','Process')
  Start-Process -FilePath $AppExe|Out-Null
  $p=Wait-App 45
  if($null-eq$p){throw 'Morning application window did not appear.'}

  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$p.MainWindowHandle)
  if($null-eq$root){throw 'UI Automation root unavailable.'}

  $Stage='connect-morning-cdp'
  $target=Wait-Target $port 45
  if($null-eq$target){throw 'Morning CDP target unavailable.'}
  $Socket=New-Object Net.WebSockets.ClientWebSocket
  $cts=New-Object Threading.CancellationTokenSource
  $cts.CancelAfter(10000)
  try{$Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,$cts.Token).GetAwaiter().GetResult()}finally{$cts.Dispose()}
  $id=1

  $Stage='prepare-clean-chat'
  [void](Send-Cdp $Socket $id 'Page.navigate' @{url='https://chatgpt.com/'});$id++
  [void](Wait-Adapter $Socket ([ref]$id) 45)
  $cleared=Clear-RecognizedDraft $Socket ([ref]$id)

  $Stage='initialize-morning-bridge'
  Invoke-Button $root 'Initialize Bridge'
  $ready=$null
  $deadline=[DateTime]::UtcNow.AddMinutes(5)
  while([DateTime]::UtcNow -lt $deadline){
    $ready=Find-ReadySession $Socket ([ref]$id)
    if($null-ne$ready -and -not [string]::IsNullOrWhiteSpace([string]$ready.session)){break}
    Start-Sleep -Milliseconds 500
  }
  if($null-eq$ready){throw 'Exact morning build did not produce LOCAL_BRIDGE_READY_V1 within 5 minutes.'}
  $Session=[string]$ready.session

  $Stage='send-morning-fsread'
  $prompt='Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose. Use tool fs.read_text with args.path C:/Windows/win.ini and args.max_chars 4096. In the JSON request, keep that path exactly with forward slashes. Wait for LOCAL_BRIDGE_RESULT_V1 before any further response.'
  $SubmitConfirmed=Send-MorningText $Socket ([ref]$id) $prompt

  $Stage='wait-morning-fsread'
  $audit=$null
  $deadline=[DateTime]::UtcNow.AddMinutes(5)
  while([DateTime]::UtcNow -lt $deadline){
    $audit=Find-FsReadAudit $Session $TestStarted
    if($null-ne$audit){break}
    Start-Sleep -Milliseconds 500
  }
  if($null-eq$audit){throw 'Exact morning build produced READY but no fs.read_text audit within 5 minutes.'}
  if(-not [bool]$audit.ok){throw ('Exact morning fs.read_text audit failed: '+($audit|ConvertTo-Json -Compress))}

  $Stage='wait-visible-final-answer'
  $answer=$null
  $deadline=[DateTime]::UtcNow.AddMinutes(5)
  while([DateTime]::UtcNow -lt $deadline){
    $answer=Find-FinalAnswer $Socket ([ref]$id)
    if(-not [string]::IsNullOrWhiteSpace([string]$answer)){break}
    Start-Sleep -Milliseconds 500
  }
  if([string]::IsNullOrWhiteSpace([string]$answer)){throw 'Exact morning fs.read_text executed, but visible final answer with win.ini content did not appear within 5 minutes.'}

  $Stage='pass'
  Finish 'pass' 0 '' @{
    session=$Session
    cleared_stale_kind=$cleared
    prompt_submit_confirmed=$SubmitConfirmed
    fs_read_audit_ok=[bool]$audit.ok
    fs_read_elapsed_ms=[long]$audit.elapsedMs
    visible_answer_excerpt=[string]$answer
    app_left_open=$true
  }
}catch{
  Finish 'fail' 31 $_.Exception.Message @{
    session=$Session
    prompt_submit_confirmed=$SubmitConfirmed
    app_left_open=(Test-Path -LiteralPath $AppExe -PathType Leaf)
  }
}finally{
  if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
  [Environment]::SetEnvironmentVariable('RUNNER_TRACKING_ID',$OldTracking,'Process')
}
