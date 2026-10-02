[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$TargetTag='dev-31e823e'
$TargetCommit='31e823ef7854a18bb2ad10e94ec71c51814628eb'
$RequestId='req-m3-live-final'
$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfo=Join-Path $InstallRoot 'release-info.json'
$LogRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$LedgerRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\state\requests'
$ProcessName='ChatGptDesktopLocalBridge'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket=$null
$Stage='start'
$BridgeStatus=''
$ConversationUri=''
$TestStarted=[DateTimeOffset]::UtcNow

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
  $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage;target_tag=$TargetTag;target_commit=$TargetCommit;request_id=$RequestId}
  foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $p|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 16 -Compress))
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
  Start-Sleep -Seconds 1
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
function Invoke-Button($Root,[string]$Name){
  $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
  $button=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
  if($null-eq$button){throw "UI button '$Name' not found."}
  $pattern=$null
  if(-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw "UI button '$Name' not invokable."}
  ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}
function Get-UiTexts($Root){
  $values=New-Object System.Collections.ArrayList
  $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  foreach($el in $all){
    try{
      if($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text){
        $n=[string]$el.Current.Name
        if(-not [string]::IsNullOrWhiteSpace($n)){[void]$values.Add($n)}
      }
    }catch{}
  }
  return @($values|Select-Object -Unique)
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
    if($null-ne$h -and [int]$h.version -ge 8 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return}
    Start-Sleep -Milliseconds 250
  }
  throw 'Adapter v8+ did not become ready.'
}
function Get-ComposerText($Socket,[ref]$Id){
  return [string](Eval $Socket $Id @'
(() => {
  const selectors=["#prompt-textarea","textarea[data-testid='prompt-textarea']","div[contenteditable='true'][data-testid='prompt-textarea']","div[contenteditable='true'][role='textbox']"];
  for(const s of selectors){const n=document.querySelector(s);if(n)return (n.innerText||n.value||n.textContent||"").trim();}
  return "";
})()
'@)
}
function Clear-KnownTestDraft($Socket,[ref]$Id){
  $text=Get-ComposerText $Socket $Id
  if([string]::IsNullOrWhiteSpace($text)){return}
  if($text -notmatch 'LOCAL-BRIDGE-'){throw 'Refusing to clear a non-test composer draft.'}
  $selected=[bool](Eval $Socket $Id @'
(() => {
  const selectors=["#prompt-textarea","textarea[data-testid='prompt-textarea']","div[contenteditable='true'][data-testid='prompt-textarea']","div[contenteditable='true'][role='textbox']"];
  let n=null; for(const s of selectors){n=document.querySelector(s);if(n)break;} if(!n)return false;
  n.focus(); if(typeof n.select==="function"){n.select();return true;}
  const sel=window.getSelection(); if(!sel)return false; const r=document.createRange(); r.selectNodeContents(n); sel.removeAllRanges(); sel.addRange(r); return true;
})()
'@)
  if(-not $selected){throw 'Known test draft could not be selected.'}
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
    if($null-ne$state -and [bool]$state.composerEmpty){return}
    Start-Sleep -Milliseconds 100
  }
  throw 'Known test draft did not clear.'
}
function Send-ChatText($Socket,[ref]$Id,[string]$Text){
  $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
  if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Chat preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
  [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
  $expected=$Text|ConvertTo-Json -Compress
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
    if($null-ne$state -and [bool]$state.textMatches){break}
    Start-Sleep -Milliseconds 100
  }
  $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
  if($null-eq$state -or -not [bool]$state.textMatches){throw 'Prompt insert was not verified.'}
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Enter';code='Enter';windowsVirtualKeyCode=13;nativeVirtualKeyCode=13});$Id.Value++
  [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Enter';code='Enter';windowsVirtualKeyCode=13;nativeVirtualKeyCode=13});$Id.Value++
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while([DateTime]::UtcNow -lt $deadline){
    $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
    if($null-ne$state -and [bool]$state.composerEmpty){return}
    Start-Sleep -Milliseconds 100
  }
  throw 'Prompt submit was not confirmed.'
}
function Find-Audit([DateTimeOffset]$StartedAfter){
  if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
  foreach($f in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
    foreach($line in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      try{
        $r=$line|ConvertFrom-Json
        $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
        if($ts -ge $StartedAfter -and [string]$r.requestId -eq $RequestId -and [string]$r.tool -eq 'fs.read_text'){return $r}
      }catch{}
    }
  }
  return $null
}
function Find-Ledger {
  if(-not(Test-Path -LiteralPath $LedgerRoot -PathType Container)){return $null}
  foreach($f in @(Get-ChildItem -LiteralPath $LedgerRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){
    try{
      $r=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8|ConvertFrom-Json
      if([string]$r.requestId -eq $RequestId){return [pscustomobject]@{file=$f.FullName;record=$r}}
    }catch{}
  }
  return $null
}
function Normalize-Conversation([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return $null}
  $u=[Uri]$Value
  $b=New-Object UriBuilder $u
  $b.Query='';$b.Fragment=''
  $p=$u.AbsolutePath.TrimEnd('/');if([string]::IsNullOrWhiteSpace($p)){$p='/'}
  $b.Path=$p
  return $b.Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')
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
  $p=Wait-App 30
  if($null-eq$p){throw 'Application window did not appear.'}
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$p.MainWindowHandle)
  if($null-eq$root){throw 'UI Automation root unavailable.'}

  $Stage='connect-cdp'
  $target=Wait-Target $port 30
  if($null-eq$target){throw 'CDP target unavailable.'}
  $Socket=New-Object Net.WebSockets.ClientWebSocket
  $Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $id=1

  $Stage='prepare-clean-chat'
  [void](Send-Cdp $Socket $id 'Page.navigate' @{url='https://chatgpt.com/'});$id++
  Wait-Adapter $Socket ([ref]$id) 30
  Clear-KnownTestDraft $Socket ([ref]$id)

  $Stage='initialize-bridge'
  Invoke-Button $root 'Initialize Bridge'
  $deadline=[DateTime]::UtcNow.AddSeconds(70)
  while([DateTime]::UtcNow -lt $deadline){
    $texts=@(Get-UiTexts $root)
    $ok=@($texts|Where-Object{$_ -like 'Bridge ready. Session*'}|Select-Object -First 1)
    if($ok.Count -gt 0){$BridgeStatus=[string]$ok[0];break}
    $fail=@($texts|Where-Object{$_ -like 'Chat send failed:*' -or $_ -like 'Could not send bridge bootstrap*' -or $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or $_ -like 'Bridge initialization failed:*'}|Select-Object -First 1)
    if($fail.Count -gt 0){throw ([string]$fail[0])}
    Start-Sleep -Milliseconds 250
  }
  if([string]::IsNullOrWhiteSpace($BridgeStatus)){throw 'Bridge READY timeout.'}

  $ConversationUri=[string](Eval $Socket ([ref]$id) 'location.href')
  $normalized=Normalize-Conversation $ConversationUri
  if([string]::IsNullOrWhiteSpace($normalized) -or $normalized -notlike 'https://chatgpt.com/c/*'){throw "No durable conversation URI: '$ConversationUri'."}

  $Stage='send-fs-read'
  $prompt='Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose. Use id '+$RequestId+'. Use tool fs.read_text with args.path C:/Windows/win.ini and args.max_chars 4096. In the JSON request, keep that path exactly with forward slashes. Wait for LOCAL_BRIDGE_RESULT_V1 before any further response.'
  Send-ChatText $Socket ([ref]$id) $prompt

  $Stage='wait-local-execution'
  $audit=$null
  $deadline=[DateTime]::UtcNow.AddSeconds(75)
  while([DateTime]::UtcNow -lt $deadline){$audit=Find-Audit $TestStarted;if($null-ne$audit){break};Start-Sleep -Milliseconds 250}
  if($null-eq$audit){throw 'No fs.read_text audit record appeared.'}
  if(-not [bool]$audit.ok){throw ('fs.read_text audit failed: '+($audit|ConvertTo-Json -Compress))}

  $Stage='verify-ledger'
  $match=$null
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while([DateTime]::UtcNow -lt $deadline){
    $match=Find-Ledger
    if($null-ne$match -and [string]$match.record.executionState -eq 'completed' -and [string]$match.record.deliveryState -eq 'delivered'){break}
    Start-Sleep -Milliseconds 250
  }
  if($null-eq$match){throw 'Durable ledger record was not found.'}
  $record=$match.record
  if([string]$record.executionState -ne 'completed'){throw "Unexpected executionState '$($record.executionState)'."}
  if([string]$record.deliveryState -ne 'delivered'){throw "Unexpected deliveryState '$($record.deliveryState)'."}
  if($null-ne$record.resultEnvelopeJson){throw 'Delivered record retained resultEnvelopeJson.'}
  if([string]$record.conversationUri -ne $normalized){throw "Conversation binding mismatch: '$($record.conversationUri)' vs '$normalized'."}

  $Stage='pass'
  Finish 'pass' 0 '' @{bridge_status=$BridgeStatus;conversation_uri=$normalized;fs_read_audit_ok=[bool]$audit.ok;fs_read_elapsed_ms=[long]$audit.elapsedMs;ledger_execution_state=[string]$record.executionState;ledger_delivery_state=[string]$record.deliveryState;delivered_payload_retired=($null-eq$record.resultEnvelopeJson);ledger_file=[string]$match.file}
}catch{
  Finish 'fail' 31 $_.Exception.Message @{bridge_status=$BridgeStatus;conversation_uri=$ConversationUri}
}finally{
  if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
  try{Stop-App}catch{}
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
  if($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){try{Start-Process -FilePath $AppExe|Out-Null}catch{}}
}