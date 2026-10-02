[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$ExpectedTag='dev-85c714c'
$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath=Join-Path $InstallRoot 'release-info.json'
$LedgerRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\state\requests'
$ProcessName='ChatGptDesktopLocalBridge'
$oldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$wasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$socket=$null
$ledgerPath=$null

function Finish([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;target_tag=$ExpectedTag}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

function Stop-App {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 1
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds=30){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|
            Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
        if($p.Count -gt 0){return $p[0]}
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Get-Root($Process){
    [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Process.MainWindowHandle)
}

function Invoke-Button($Root,[string]$Name){
    $cond=New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,$Name)
    $button=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
    if($null-eq$button){throw "UI button '$Name' not found."}
    $pattern=$null
    if(-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
        throw "UI button '$Name' not invokable."
    }
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
    @($values|Select-Object -Unique)
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=30){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $target=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($target.Count -gt 0){return $target[0]}
        }catch{}
        Start-Sleep -Milliseconds 300
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
    $r.result.result.value
}

function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=35){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $health=Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
        if($null-ne$health -and [int]$health.version -ge 8 -and [bool]$health.nativeInputReady){return}
        Start-Sleep -Milliseconds 300
    }
    throw 'Adapter v8 did not become ready.'
}

function Send-Text($Socket,[ref]$Id,[string]$Text){
    $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false}'
    if($null-eq$prepare -or -not [bool]$prepare.accepted){throw 'Chat composer preflight rejected.'}
    [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
    $expected=$Text|ConvertTo-Json -Compress
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
        if($null-ne$state -and [bool]$state.textMatches){break}
        Start-Sleep -Milliseconds 100
    }
    $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false}'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw 'Chat submit rejected.'}
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $Socket $Id 'window.__localBridge?.nativeSendState?.() ?? null'
        if($null-ne$state -and [bool]$state.composerEmpty){return}
        Start-Sleep -Milliseconds 100
    }
    throw 'Chat submit was not confirmed.'
}

try{
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$release.tag -ne $ExpectedTag){throw "Installed release '$($release.tag)' is not '$ExpectedTag'."}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $port=Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')

    Stop-App
    Start-Process -FilePath $AppExe|Out-Null
    $p=Wait-App
    if($null-eq$p){throw 'Application did not start.'}
    $root=Get-Root $p
    $target=Wait-Target $port
    if($null-eq$target){throw 'CDP target unavailable.'}
    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1
    Wait-Adapter $socket ([ref]$id)

    $marker='LOCAL-BRIDGE-RECOVERY-CONTEXT-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    Send-Text $socket ([ref]$id) ('Reply with exactly this single line and no other text: '+$marker)

    $conversationUrl=''
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while([DateTime]::UtcNow -lt $deadline){
        $conversationUrl=[string](Eval $socket ([ref]$id) 'location.href')
        if($conversationUrl -match '^https://chatgpt\.com/c/'){break}
        Start-Sleep -Milliseconds 300
    }
    if($conversationUrl -notmatch '^https://chatgpt\.com/c/'){throw 'Dedicated conversation URL was not created.'}

    $session=[Guid]::NewGuid().ToString('N')
    $requestId='req-recovery-'+[Guid]::NewGuid().ToString('N').Substring(0,10)
    $normalized=([Uri]$conversationUrl).GetLeftPart([UriPartial]::Path).TrimEnd('/')
    $resultJson=@{session=$session;request_id=$requestId;ok=$true;result=@{probe='crash-recovery'}}|ConvertTo-Json -Depth 6 -Compress
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    $record=[ordered]@{
        schema='local-bridge-request-ledger-v1'
        session=$session
        requestId=$requestId
        tool='system.info'
        fingerprintSha256=('0'*64)
        executionState='completed'
        deliveryState='pending'
        createdUtc=$now
        updatedUtc=$now
        ok=$true
        errorCode=$null
        elapsedMs=1
        resultEnvelopeJson=$resultJson
        conversationUri=$normalized
    }

    New-Item -ItemType Directory -Force -Path $LedgerRoot|Out-Null
    $keyBytes=[Text.Encoding]::UTF8.GetBytes($session+"\n"+$requestId)
    $key=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($keyBytes))).Replace('-','').ToLowerInvariant()
    $ledgerPath=Join-Path $LedgerRoot ($key+'.json')
    $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ledgerPath -Encoding UTF8

    $socket.Dispose();$socket=$null
    Stop-App
    Start-Process -FilePath $AppExe|Out-Null
    $p=Wait-App
    if($null-eq$p){throw 'Application did not restart.'}
    $root=Get-Root $p
    $target=Wait-Target $port
    if($null-eq$target){throw 'Restarted CDP target unavailable.'}
    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1
    [void](Send-Cdp $socket $id 'Page.navigate' @{url=$conversationUrl});$id++
    Wait-Adapter $socket ([ref]$id) 45

    Invoke-Button $root 'Initialize Bridge'
    $resumed=''
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $root)
        $ok=@($texts|Where-Object{$_ -like 'Bridge resumed. Session*'}|Select-Object -First 1)
        if($ok.Count -gt 0){$resumed=[string]$ok[0];break}
        $fail=@($texts|Where-Object{$_ -like 'Bridge initialization failed:*' -or $_ -like 'Bridge recovery is blocked:*' -or $_ -like 'Chat send failed:*'}|Select-Object -First 1)
        if($fail.Count -gt 0){throw ([string]$fail[0])}
        Start-Sleep -Milliseconds 250
    }
    if([string]::IsNullOrWhiteSpace($resumed)){throw 'Bridge did not resume pending delivery.'}

    $seen=[bool](Eval $socket ([ref]$id) ('window.__localBridge?.hasResult?.('+
        ($session|ConvertTo-Json -Compress)+','+($requestId|ConvertTo-Json -Compress)+') ?? false'))
    if(-not $seen){throw 'Recovered result is not present in the originating conversation.'}

    $after=Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$after.deliveryState -ne 'delivered'){throw 'Recovered durable record is not marked delivered.'}

    Finish 'pass' 0 '' @{
        conversation_scoped=$true
        result_visible=$true
        delivery_state=[string]$after.deliveryState
        session_prefix=$session.Substring(0,8)
        request_id=$requestId
    }
}catch{
    Finish 'fail' 31 $_.Exception.Message
}finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    if($ledgerPath -and (Test-Path -LiteralPath $ledgerPath)){Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
    if($wasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){try{Start-Process -FilePath $AppExe|Out-Null}catch{}}
}
