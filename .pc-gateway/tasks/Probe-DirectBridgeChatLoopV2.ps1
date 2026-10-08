[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$PackageTag='direct-bridge-test-6ab0c4d'
$AssetName='ChatGptDesktopLocalBridge-DirectBridge.zip'
$ExpectedSha256='021f4ef850f88586b3dd98837db04d8b2f77b61c5602f58f405750cc6eefdf73'
$AssetUrl='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/'+$PackageTag+'/'+$AssetName
$ProcessName='ChatGptDesktopLocalBridge'
$InstalledAppExe=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$LogRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$WorkRoot=Join-Path $env:TEMP ('direct-bridge-e2e-v2-'+[Guid]::NewGuid().ToString('N'))
$ZipPath=Join-Path $WorkRoot $AssetName
$AppRoot=Join-Path $WorkRoot 'app'
$AppExe=Join-Path $AppRoot 'ChatGptDesktopLocalBridge.exe'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket=$null
$Stage='init'
$Started=[DateTimeOffset]::UtcNow
$BridgeStatus=''
$SessionPrefix=''

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage;package_tag=$PackageTag}
    foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
    $d=Split-Path -Parent $GatewayResultPath
    if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
    $p|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 20 -Compress))
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

function Wait-App([int]$TimeoutSeconds=45){
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

function Send-Cdp($S,[int]$Id,[string]$Method,[hashtable]$Params=@{},[int]$TimeoutMs=15000){
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]$S.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while($true){
            $ms=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $rxseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $rx=$S.ReceiveAsync($rxseg,$cts.Token).GetAwaiter().GetResult()
                    if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP socket closed.'}
                    $ms.Write($buf,0,$rx.Count)
                }while(-not $rx.EndOfMessage)
                $msg=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
                if($null-ne$msg.PSObject.Properties['id'] -and [int]$msg.id -eq $Id){return $msg}
            }finally{$ms.Dispose()}
        }
    }finally{$cts.Dispose()}
}

function Eval($S,[ref]$Id,[string]$Expression){
    $r=Send-Cdp $S $Id.Value 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true}
    $Id.Value++
    if($null-ne$r.PSObject.Properties['error']){throw ('CDP error: '+($r.error|ConvertTo-Json -Compress))}
    if($null-ne$r.result.PSObject.Properties['exceptionDetails']){throw ('CDP JS exception: '+($r.result.exceptionDetails|ConvertTo-Json -Compress))}
    return $r.result.result.value
}

function Connect-ReadyRoot([int]$Port,[int]$TimeoutSeconds=90){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last='none'
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $roots=@($items|Where-Object{$_.type -eq 'page' -and ([string]$_.url).TrimEnd('/') -eq 'https://chatgpt.com' -and $_.webSocketDebuggerUrl})
            foreach($target in $roots){
                $s=New-Object Net.WebSockets.ClientWebSocket
                try{
                    $s.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
                    $id=1
                    $h=Eval $s ([ref]$id) 'window.__localBridge && window.__localBridge.health ? window.__localBridge.health() : null'
                    if($null-ne$h){
                        $last=($h|ConvertTo-Json -Depth 8 -Compress)
                        if([int]$h.version -ge 11 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady -and [bool]$h.sendReceiptAvailable){
                            return @{socket=$s;health=$h;id=$id}
                        }
                    }
                }catch{
                    $last=[string]$_.Exception.Message
                }
                if($null-ne$s){try{$s.Dispose()}catch{}}
            }
        }catch{
            $last=[string]$_.Exception.Message
        }
        Start-Sleep -Milliseconds 750
    }
    throw ('No root ChatGPT WebView with a ready composer. Last='+$last)
}

function Send-ChatText($S,[ref]$Id,[string]$Text){
    $before=Eval $S $Id 'window.__localBridge.nativeSendReceipt(null,0)'
    $baseline=[int]$before.userMessageCount
    $prepare=Eval $S $Id 'window.__localBridge.prepareNativeSend()'
    if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Chat preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
    [void](Send-Cdp $S $Id.Value 'Input.insertText' @{text=$Text})
    $Id.Value++
    $expected=$Text|ConvertTo-Json -Compress
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    $matched=$false
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $S $Id ('window.__localBridge.nativeSendState('+$expected+')')
        if($null-ne$state -and [bool]$state.textMatches){$matched=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $matched){throw 'Inserted chat text was not verified.'}
    $submit=Eval $S $Id 'window.__localBridge.submitNativeSend()'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Chat submit rejected: '+($submit|ConvertTo-Json -Compress))}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while([DateTime]::UtcNow -lt $deadline){
        $receipt=Eval $S $Id ('window.__localBridge.nativeSendReceipt('+$expected+','+$baseline+')')
        if($null-ne$receipt -and [bool]$receipt.confirmed){return $receipt}
        Start-Sleep -Milliseconds 200
    }
    throw 'Exact new user message was not confirmed after submit.'
}

function Wait-BridgeReady($Root,[int]$TimeoutSeconds=100){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $Root)
        foreach($item in $texts){
            $value=[string]$item
            if($value -match "([0-9a-fA-F]{8})"){
                return $value
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Bridge READY timeout."
}

function Wait-Marker($S,[ref]$Id,[string]$Marker,[int]$TimeoutSeconds=240){
    $expr="Array.from(document.querySelectorAll('[data-message-author-role=assistant],[data-markdown-text-style=assistant-message]')).map(function(x){return (x.innerText || x.textContent || '');})"
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Eval $S $Id $expr)
        foreach($item in $texts){
            $value=[string]$item
            if($value.Contains($Marker)){
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Find-Audit([string]$Tool,[string]$SessionPrefix,[DateTimeOffset]$StartedAfter){
    if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
    foreach($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 4)){
        foreach($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)){
            if([string]::IsNullOrWhiteSpace($line)){continue}
            try{
                $r=$line|ConvertFrom-Json
                $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
                if($ts -ge $StartedAfter -and [string]$r.session -like ($SessionPrefix+'*') -and [string]$r.tool -eq $Tool){return $r}
            }catch{}
        }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $WorkRoot|Out-Null

try{
    $Stage='download'
    Invoke-WebRequest -UseBasicParsing -Uri $AssetUrl -OutFile $ZipPath

    $Stage='hash'
    $actual=([string](Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash).ToLowerInvariant()
    if($actual -ne $ExpectedSha256){throw "Package SHA256 mismatch: $actual"}

    $Stage='extract'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $AppRoot -Force
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'Test application executable is missing.'}

    $Stage='start'
    $port=Get-Random -Minimum 9400 -Maximum 9999
    Stop-App
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    $app=Wait-App 45
    if($null-eq$app){throw 'Application window did not appear.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if($null-eq$root){throw 'UI Automation root unavailable.'}

    $Stage='new-chat'
    Invoke-Button $root '+ Чат'
    Start-Sleep -Seconds 5

    $Stage='composer'
    $ready=Connect-ReadyRoot $port 90
    $Socket=$ready.socket
    $health=$ready.health
    $id=[int]$ready.id

    $Stage='bridge'
    Invoke-Button $root 'Мост'
    $BridgeStatus=Wait-BridgeReady $root 100
    if($BridgeStatus -notmatch '([0-9a-fA-F]{8})'){throw ('Could not parse bridge session from status: '+$BridgeStatus)}
    $SessionPrefix=$Matches[1].ToLowerInvariant()

    Start-Sleep -Seconds 5

    $Stage='prompt'
    $prompt='Use only the current direct Local Bridge. Do not use local.intent. First call fs.read_text for C:/Windows/win.ini with max_chars 4096 and wait for LOCAL_BRIDGE_RESULT_V1. Then call system.info with empty args and wait for LOCAL_BRIDGE_RESULT_V1. After both results, reply with exactly DIRECT_BRIDGE_E2E_PASS and nothing else.'
    $receipt=Send-ChatText $Socket ([ref]$id) $prompt

    $Stage='model-loop'
    if(-not(Wait-Marker $Socket ([ref]$id) 'DIRECT_BRIDGE_E2E_PASS' 240)){throw 'Final DIRECT_BRIDGE_E2E_PASS marker was not produced.'}

    $Stage='audit'
    $fs=Find-Audit 'fs.read_text' $SessionPrefix $Started
    $sys=Find-Audit 'system.info' $SessionPrefix $Started
    $intent=Find-Audit 'local.intent' $SessionPrefix $Started
    if($null-eq$fs){throw 'fs.read_text audit record missing.'}
    if($null-eq$sys){throw 'system.info audit record missing.'}
    if(-not [bool]$fs.ok){throw 'fs.read_text audit record is not ok.'}
    if(-not [bool]$sys.ok){throw 'system.info audit record is not ok.'}
    if($null-ne$intent){throw 'local.intent was used during direct bridge E2E.'}
    if([string]$fs.session -ne [string]$sys.session){throw 'Two local steps used different bridge sessions.'}

    $Stage='result-dom'
    $sessionJson=([string]$fs.session)|ConvertTo-Json -Compress
    $fsIdJson=([string]$fs.requestId)|ConvertTo-Json -Compress
    $sysIdJson=([string]$sys.requestId)|ConvertTo-Json -Compress
    $fsVisible=[bool](Eval $Socket ([ref]$id) ('window.__localBridge.hasResult('+$sessionJson+','+$fsIdJson+')'))
    $sysVisible=[bool](Eval $Socket ([ref]$id) ('window.__localBridge.hasResult('+$sessionJson+','+$sysIdJson+')'))
    if(-not$fsVisible){throw 'First LOCAL_BRIDGE_RESULT_V1 is not visible in the same conversation.'}
    if(-not$sysVisible){throw 'Second LOCAL_BRIDGE_RESULT_V1 is not visible in the same conversation.'}

    $Stage='pass'
    Finish 'pass' 0 '' @{
        adapter_version=[int]$health.version
        prompt_confirmed=[bool]$receipt.confirmed
        bridge_status=$BridgeStatus
        session_prefix=$SessionPrefix
        fs_request_id=[string]$fs.requestId
        system_request_id=[string]$sys.requestId
        fs_result_visible=$fsVisible
        system_result_visible=$sysVisible
        local_intent_used=$false
        final_marker='DIRECT_BRIDGE_E2E_PASS'
    }
}catch{
    Finish 'fail' 31 (([string]$_.Exception.Message)+' | stage='+$Stage+' | line='+([string]$_.InvocationInfo.ScriptLineNumber))
}finally{
    if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    if($WasRunning -and (Test-Path -LiteralPath $InstalledAppExe -PathType Leaf)){
        try{Start-Process -FilePath $InstalledAppExe|Out-Null}catch{}
    }
}
