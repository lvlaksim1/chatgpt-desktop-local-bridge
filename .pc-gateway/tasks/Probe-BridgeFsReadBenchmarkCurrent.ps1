[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$TargetTag='dev-265d63b'
$TargetCommit='265d63b4a04a3c3e887af7f2c5159ba80098acce'
$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfo=Join-Path $InstallRoot 'release-info.json'
$LogRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$ProcessName='ChatGptDesktopLocalBridge'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket=$null
$Stage='start'
$TestStarted=[DateTimeOffset]::UtcNow

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage;target_tag=$TargetTag;target_commit=$TargetCommit}
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
        if($null-ne$h -and [int]$h.version -ge 9 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return $h}
        Start-Sleep -Milliseconds 250
    }
    throw 'Adapter v9+ did not become ready.'
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
  const diag=text.startsWith("LOCAL-BRIDGE-");
  const recognized=bridge||probe||diag;
  if(recognized){
    n.focus();
    if(typeof n.select==="function")n.select();
    else{const s=window.getSelection();const r=document.createRange();r.selectNodeContents(n);s.removeAllRanges();s.addRange(r);}
  }
  return {empty:false,recognized,kind:bridge?"bridge-envelope":probe?"fsread-probe":diag?"diag":"unrecognized"};
})()
'@
    if([bool]$c.empty){return [string]$c.kind}
    if(-not [bool]$c.recognized){throw 'Composer contains an unrecognized user draft; benchmark left it untouched.'}
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while([DateTime]::UtcNow -lt $deadline){
        $s=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
        if($null-ne$s -and [bool]$s.composerEmpty){return [string]$c.kind}
        Start-Sleep -Milliseconds 100
    }
    throw 'Recognized stale draft did not clear.'
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

function Send-BenchmarkPrompt($Socket,[ref]$Id,[string]$Text){
    $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Benchmark preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
    [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
    $expected=$Text|ConvertTo-Json -Compress
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    $inserted=$false
    while([DateTime]::UtcNow -lt $deadline){
        $s=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
        if($null-ne$s -and [bool]$s.textMatches){$inserted=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $inserted){throw 'Benchmark prompt insert was not verified.'}

    $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Benchmark prompt submit rejected: '+($submit|ConvertTo-Json -Compress))}

    $confirmed=$false
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while([DateTime]::UtcNow -lt $deadline){
        $s=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
        if($null-ne$s -and [bool]$s.composerEmpty){$confirmed=$true;break}
        Start-Sleep -Milliseconds 100
    }
    return $confirmed
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
    if(t.includes("MAPI=1") && (t.includes("[Mail]") || t.includes("16-bit app support"))) return t.slice(0,4000);
  }
  return null;
})()
'@
}

$port=Get-Random -Minimum 9400 -Maximum 9999
$bridgeUiStatus=''
$session=''

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
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    try{$Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,$cts.Token).GetAwaiter().GetResult()}finally{$cts.Dispose()}
    $id=1

    $Stage='clean-chat'
    [void](Send-Cdp $Socket $id 'Page.navigate' @{url='https://chatgpt.com/'});$id++
    [void](Wait-Adapter $Socket ([ref]$id) 30)
    $cleared=Clear-RecognizedDraft $Socket ([ref]$id)

    $Stage='initialize-bridge'
    Invoke-Button $root 'Initialize Bridge'

    $ready=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    while([DateTime]::UtcNow -lt $deadline){
        $ready=Find-ReadySession $Socket ([ref]$id)
        if($null-ne$ready -and -not [string]::IsNullOrWhiteSpace([string]$ready.session)){break}

        $texts=@(Get-UiTexts $root)
        $status=@($texts|Where-Object{$_ -like 'Bridge ready. Session*' -or $_ -like 'Chat send failed:*' -or $_ -like 'Bootstrap sent.*'}|Select-Object -Last 1)
        if($status.Count -gt 0){$bridgeUiStatus=[string]$status[0]}

        Start-Sleep -Milliseconds 500
    }
    if($null-eq$ready){throw ('No LOCAL_BRIDGE_READY_V1 appeared within 180 seconds. UI='+$bridgeUiStatus)}
    $session=[string]$ready.session

    $Stage='send-fsread-prompt'
    $prompt='Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose. Use tool fs.read_text with args.path C:/Windows/win.ini and args.max_chars 4096. In the JSON request, keep that path exactly with forward slashes. Wait for LOCAL_BRIDGE_RESULT_V1 before any further response.'
    $promptSubmitConfirmed=Send-BenchmarkPrompt $Socket ([ref]$id) $prompt

    $Stage='wait-fsread-audit'
    $audit=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    while([DateTime]::UtcNow -lt $deadline){
        $audit=Find-FsReadAudit $session $TestStarted
        if($null-ne$audit){break}
        Start-Sleep -Milliseconds 500
    }
    if($null-eq$audit){throw 'No fs.read_text audit record appeared within 180 seconds.'}
    if(-not [bool]$audit.ok){throw ('fs.read_text audit failed: '+($audit|ConvertTo-Json -Compress))}

    $Stage='wait-final-answer'
    $answer=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    while([DateTime]::UtcNow -lt $deadline){
        $answer=Find-FinalAnswer $Socket ([ref]$id)
        if(-not [string]::IsNullOrWhiteSpace([string]$answer)){break}
        Start-Sleep -Milliseconds 500
    }
    if([string]::IsNullOrWhiteSpace([string]$answer)){throw 'fs.read_text executed, but no final ChatGPT answer containing win.ini content appeared within 180 seconds.'}

    $Stage='pass'
    Finish 'pass' 0 '' @{
        session=$session
        bridge_ui_status=$bridgeUiStatus
        cleared_stale_kind=$cleared
        prompt_submit_confirmed=$promptSubmitConfirmed
        fs_read_audit_ok=[bool]$audit.ok
        fs_read_elapsed_ms=[long]$audit.elapsedMs
        answer_excerpt=[string]$answer
    }
}catch{
    Finish 'fail' 31 $_.Exception.Message @{
        session=$session
        bridge_ui_status=$bridgeUiStatus
    }
}finally{
    if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    if($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){try{Start-Process -FilePath $AppExe|Out-Null}catch{}}
}
