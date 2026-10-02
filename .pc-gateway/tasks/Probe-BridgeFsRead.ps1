[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$TargetTag = 'dev-ea074e0'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$LogRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$ProcessName = 'ChatGptDesktopLocalBridge'
$oldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$wasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$socket = $null

function Write-Result {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;target_tag=$TargetTag}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 16 -Compress))
    exit $ExitCode
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
        Start-Sleep -Milliseconds 500
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

function Get-Diagnostics($Root){
    Invoke-Button $Root 'Diagnostics'
    Start-Sleep -Milliseconds 700
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'Local Bridge diagnostics')
    $dialog=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
    if($null-eq$dialog){return 'diagnostics-dialog-not-found'}
    $parts=New-Object System.Collections.ArrayList
    $all=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all){
        try{
            $n=[string]$el.Current.Name
            if(-not [string]::IsNullOrWhiteSpace($n)){[void]$parts.Add($n)}
        }catch{}
    }
    try{
        $okCond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'OK')
        $ok=$dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$okCond)
        if($null-ne$ok){
            $pat=$null
            if($ok.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pat)){([System.Windows.Automation.InvokePattern]$pat).Invoke()}
        }
    }catch{}
    return (@($parts|Select-Object -Unique)-join ' || ')
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=30){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $target=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($target.Count -gt 0){return $target[0]}
        }catch{}
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Send-Cdp($Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{}){
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $segment=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    try{
        [void]$Socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while($true){
            $ms=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $seg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $rx=$Socket.ReceiveAsync($seg,$cts.Token).GetAwaiter().GetResult()
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

function Send-ChatText($Socket,[ref]$Id,[string]$Text){
    $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Chat preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
    [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
    $expected=$Text|ConvertTo-Json -Compress
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    $inserted=$false
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
        if($null-ne$state -and [bool]$state.textMatches){$inserted=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $inserted){throw 'Prompt insert was not verified.'}
    $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Prompt submit rejected: '+($submit|ConvertTo-Json -Compress))}
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
        if($null-ne$state -and [bool]$state.composerEmpty){return}
        Start-Sleep -Milliseconds 100
    }
    throw 'Prompt submit was not confirmed.'
}

function Find-FsReadAudit([string]$SessionPrefix,[DateTimeOffset]$StartedAfter){
    if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
    foreach($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
        foreach($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)){
            if([string]::IsNullOrWhiteSpace($line)){continue}
            try{
                $r=$line|ConvertFrom-Json
                $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
                if($ts -lt $StartedAfter){continue}
                if([string]$r.session -like ($SessionPrefix+'*') -and [string]$r.tool -eq 'fs.read_text'){return $r}
            }catch{}
        }
    }
    return $null
}

$port=Get-Random -Minimum 9400 -Maximum 9999
$testStarted=[DateTimeOffset]::UtcNow
$bridgeStatus=''
$sessionPrefix=''

try{
    if(-not(Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)){throw 'release-info.json is missing.'}
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$release.tag -ne $TargetTag){throw "Installed release is '$($release.tag)', expected '$TargetTag'."}

    Stop-App
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    $p=Wait-App 30
    if($null-eq$p){throw 'Application window did not appear.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$p.MainWindowHandle
    )
    if($null-eq$root){throw 'UI Automation root unavailable.'}

    $diag=''
    $ready=$false
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while([DateTime]::UtcNow -lt $deadline){
        $diag=Get-Diagnostics $root
        if($diag -match '"version"\s*:\s*5' -and $diag -match '"composerFound"\s*:\s*true' -and $diag -match '"nativeInputReady"\s*:\s*true'){$ready=$true;break}
        Start-Sleep -Seconds 2
    }
    if(-not $ready){throw ('Adapter/composer not ready: '+$diag)}

    $target=Wait-Target $port 30
    if($null-eq$target){throw 'CDP target unavailable.'}
    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1

    Invoke-Button $root 'Initialize Bridge'
    $deadline=[DateTime]::UtcNow.AddSeconds(70)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $root)
        $ok=@($texts|Where-Object{$_ -like 'Bridge ready. Session*'}|Select-Object -First 1)
        if($ok.Count -gt 0){$bridgeStatus=[string]$ok[0];break}
        $fail=@($texts|Where-Object{$_ -like 'Chat send failed:*' -or $_ -like 'Could not send bridge bootstrap*' -or $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or $_ -like 'Bridge initialization failed:*'}|Select-Object -First 1)
        if($fail.Count -gt 0){throw ([string]$fail[0])}
        Start-Sleep -Milliseconds 500
    }
    if([string]::IsNullOrWhiteSpace($bridgeStatus)){throw 'Bridge READY timeout.'}
    if($bridgeStatus -notmatch 'Session\s+([0-9a-fA-F]{8})'){throw ('Could not parse session from: '+$bridgeStatus)}
    $sessionPrefix=$Matches[1].ToLowerInvariant()

    $prompt='Use the current Local Bridge session. Respond with EXACTLY ONE LOCAL_BRIDGE_REQUEST_V1 request and no human prose. Use tool fs.read_text with args.path C:/Windows/win.ini and args.max_chars 4096. In the JSON request, keep that path exactly with forward slashes. Wait for LOCAL_BRIDGE_RESULT_V1 before any further response.'
    Send-ChatText $socket ([ref]$id) $prompt

    $audit=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(75)
    while([DateTime]::UtcNow -lt $deadline){
        $audit=Find-FsReadAudit $sessionPrefix $testStarted
        if($null-ne$audit){break}
        Start-Sleep -Milliseconds 500
    }
    if($null-eq$audit){
        $assistantDiag=Eval $socket ([ref]$id) @'
(() => {
  const nodes=Array.from(document.querySelectorAll("[data-markdown-text-style='assistant-message'], [data-message-author-role='assistant']"));
  return nodes.slice(-6).map(n => (n.innerText || n.textContent || "").trim().slice(0,2400));
})()
'@
        $uiDiag=@(Get-UiTexts $root|Select-Object -Last 12)
        throw ('No fs.read_text audit record appeared within 75 seconds. ASSISTANT='+
            ($assistantDiag|ConvertTo-Json -Depth 6 -Compress)+' UI='+
            ($uiDiag|ConvertTo-Json -Depth 6 -Compress))
    }
    if(-not [bool]$audit.ok){throw ('fs.read_text audit failed: '+($audit|ConvertTo-Json -Compress))}

    Write-Result 'pass' 0 '' @{
        bridge_status=$bridgeStatus
        session_prefix=$sessionPrefix
        fs_read_audit_ok=[bool]$audit.ok
        fs_read_elapsed_ms=[long]$audit.elapsedMs
    }
}catch{
    Write-Result 'fail' 31 $_.Exception.Message @{
        bridge_status=$bridgeStatus
        session_prefix=$sessionPrefix
    }
}finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
    if($wasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){
        try{Start-Process -FilePath $AppExe|Out-Null}catch{}
    }
}