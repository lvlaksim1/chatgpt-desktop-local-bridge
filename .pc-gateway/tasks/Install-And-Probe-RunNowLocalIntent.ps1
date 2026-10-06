[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$BaseTag='private-transport-v5-95dd011'
$BaseCommit='95dd011593fd28b570831fc2995d26bef0691f27'
$TargetTag='local-bridge-runnow-de8284e'
$TargetCommit='de8284e1cbe0213d17ff54d3c725eaa31706a101'
$AssetName='ChatGptDesktopLocalBridge-Update-from-private-transport-v5-95dd011.exe'
$ExpectedSha256='e57f87173f6a52cad467cec5bf820d5c1bd1c46b5817998bab45ef074e04456c'

$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfo=Join-Path $InstallRoot 'release-info.json'
$LogRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$SourcePath='D:\test\file.txt'
$DestinationPath='D:\test\file1.txt'
$ProcessName='ChatGptDesktopLocalBridge'
$TempRoot=Join-Path $env:TEMP ('bridge-runnow-update-'+[Guid]::NewGuid().ToString('N'))
$UpdateExe=Join-Path $TempRoot $AssetName
$UpdateLog=Join-Path $TempRoot 'update.log'
$OldSkip=[Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','Process')
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket=$null
$Stage='start'
$TestStarted=[DateTimeOffset]::UtcNow
$SessionPrefix=''

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $p=[ordered]@{
        status=$Status
        error=$ErrorText
        exit_code=$Code
        stage=$Stage
        base_tag=$BaseTag
        target_tag=$TargetTag
        target_commit=$TargetCommit
    }
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

function Wait-App([int]$TimeoutSeconds=30){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
        if($p.Count -gt 0){return $p[0]}
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=45){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $t=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($t.Count -gt 0){return $t[0]}
        }catch{}
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Send-Cdp($Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{}){
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(15000)
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
    if($null-ne$r.result.PSObject.Properties['exceptionDetails']){throw ('CDP JS exception: '+($r.result.exceptionDetails|ConvertTo-Json -Compress))}
    return $r.result.result.value
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

function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=45){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $h=Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
        if($null-ne$h -and [int]$h.version -ge 10 -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return $h}
        Start-Sleep -Milliseconds 500
    }
    throw 'Adapter v10+ did not become ready.'
}

function Clear-Composer($Socket,[ref]$Id){
    $r=Eval $Socket $Id @'
(() => {
  const n=document.querySelector("#prompt-textarea,textarea[data-testid='prompt-textarea'],div[contenteditable='true'][data-testid='prompt-textarea'],div[contenteditable='true'][role='textbox']");
  if(!n)return {ok:false,reason:"not-found"};
  const text=(n.innerText||n.value||n.textContent||"").trim();
  if(!text)return {ok:true,empty:true};
  if(text.startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||text.startsWith("[[LOCAL_BRIDGE_RESULT_V1]]")){
    n.focus();
    if(typeof n.select==="function")n.select();
    else{const s=window.getSelection();const rr=document.createRange();rr.selectNodeContents(n);s.removeAllRanges();s.addRange(rr);}
    return {ok:true,empty:false,selected:true};
  }
  return {ok:false,reason:"unrecognized-draft",textLength:text.length};
})()
'@
    if(-not [bool]$r.ok){throw ('Composer is not safe to clear: '+($r|ConvertTo-Json -Compress))}
    if([bool]$r.empty){return}
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    Start-Sleep -Milliseconds 300
}

function Send-ChatText($Socket,[ref]$Id,[string]$Text){
    $prepare=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$prepare -or -not [bool]$prepare.accepted){throw ('Chat preflight rejected: '+($prepare|ConvertTo-Json -Compress))}
    [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
    $expected=$Text|ConvertTo-Json -Compress
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
        if($null-ne$state -and [bool]$state.textMatches){break}
        Start-Sleep -Milliseconds 150
    }
    $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Prompt submit rejected: '+($submit|ConvertTo-Json -Compress))}
}

function Try-ApprovePermission {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    while([DateTime]::UtcNow -lt $deadline){
        foreach($title in @('Разрешение Local Bridge','Local Bridge permission')){
            $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$title)
            $dialog=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
            if($null-eq$dialog){continue}
            foreach($name in @('Да','Yes')){
                $bc=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
                $button=$dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$bc)
                if($null-ne$button){
                    $pattern=$null
                    if($button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
                        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                        return $true
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Find-Audit([string]$Tool,[DateTimeOffset]$StartedAfter){
    if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
    foreach($f in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
        foreach($line in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)){
            if([string]::IsNullOrWhiteSpace($line)){continue}
            try{
                $r=$line|ConvertFrom-Json
                $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
                if($ts -ge $StartedAfter -and [string]$r.tool -eq $Tool){return $r}
            }catch{}
        }
    }
    return $null
}

function Decode-SourceText([byte[]]$Bytes){
    if($Bytes.Length -ge 3 -and $Bytes[0]-eq 0xEF -and $Bytes[1]-eq 0xBB -and $Bytes[2]-eq 0xBF){
        return [Text.Encoding]::UTF8.GetString($Bytes,3,$Bytes.Length-3)
    }
    try{
        $u=New-Object Text.UTF8Encoding -ArgumentList @($false,$true)
        return $u.GetString($Bytes)
    }catch{
        return [Text.Encoding]::GetEncoding(1251).GetString($Bytes)
    }
}

try{
    $Stage='verify-base'
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'Installed application executable is missing.'}
    if(-not(Test-Path -LiteralPath $ReleaseInfo -PathType Leaf)){throw 'Installed release marker is missing.'}

    $before=Get-Content -LiteralPath $ReleaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    $alreadyCurrent=([string]$before.tag -eq $TargetTag -and [string]$before.commit -eq $TargetCommit)
    if(-not $alreadyCurrent -and ([string]$before.tag -ne $BaseTag -or [string]$before.commit -ne $BaseCommit)){
        throw "Installed base mismatch: '$($before.tag)' '$($before.commit)'."
    }

    if(-not $alreadyCurrent){
        $Stage='download-update'
        New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
        $url='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/'+$TargetTag+'/'+$AssetName
        $wc=New-Object Net.WebClient
        try{$wc.DownloadFile($url,$UpdateExe)}finally{$wc.Dispose()}

        $actual=(Get-FileHash -LiteralPath $UpdateExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -ne $ExpectedSha256){throw "Updater hash mismatch: $actual"}

        Start-Sleep -Seconds 5
        $Stage='install-update'
        Stop-App
        [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')
        $p=Start-Process -FilePath $UpdateExe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$UpdateLog)) -PassThru
        if(-not $p.WaitForExit(120000)){
            try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
            throw 'Updater timed out after 120 seconds.'
        }
        $p.Refresh()
        if($p.ExitCode -ne 0){throw "Updater failed with exit code $($p.ExitCode)."}
    }

    $Stage='verify-target'
    $after=Get-Content -LiteralPath $ReleaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$after.tag -ne $TargetTag -or [string]$after.commit -ne $TargetCommit){
        throw "Target marker mismatch: '$($after.tag)' '$($after.commit)'."
    }

    Add-Type -AssemblyName System.Drawing
    $icon=[System.Drawing.Icon]::ExtractAssociatedIcon($AppExe)
    $iconOk=$null-ne$icon
    if($null-ne$icon){$icon.Dispose()}
    if(-not $iconOk){throw 'Application icon could not be extracted from the updated executable.'}

    $Stage='start-updated-app'
    $port=Get-Random -Minimum 9400 -Maximum 9999
    Stop-App
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    $app=Wait-App 40
    if($null-eq$app){throw 'Updated application window did not appear.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if($null-eq$root){throw 'UI Automation root unavailable.'}

    $Stage='connect-chat'
    $target=Wait-Target $port 45
    if($null-eq$target){throw 'ChatGPT WebView target unavailable.'}
    $Socket=New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1
    [void](Wait-Adapter $Socket ([ref]$id) 45)
    Clear-Composer $Socket ([ref]$id)

    $Stage='initialize-bridge'
    Invoke-Button $root 'Initialize Bridge'
    $deadline=[DateTime]::UtcNow.AddSeconds(100)
    $bridgeReady=$false
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $root)
        $ready=@($texts|Where-Object{$_ -like 'Мост готов*' -or $_ -like 'Bridge ready*'}|Select-Object -Last 1)
        if($ready.Count -gt 0){$bridgeReady=$true;break}
        Start-Sleep -Milliseconds 500
    }
    if(-not $bridgeReady){throw 'Bridge READY timeout.'}

    Start-Sleep -Seconds 5

    $Stage='send-natural-command'
    $command='Возьми файл D:\test\file.txt. Извлеки из него первую строку и создай файл D:\test\file1.txt, содержащий извлечённые данные.'
    Send-ChatText $Socket ([ref]$id) $command

    $permissionTask=[System.Threading.Tasks.Task]::Run([Action]{ [void](Try-ApprovePermission) })

    $Stage='wait-local-intent'
    $audit=$null
    $deadline=[DateTime]::UtcNow.AddMinutes(3)
    while([DateTime]::UtcNow -lt $deadline){
        $audit=Find-Audit 'local.intent' $TestStarted
        if($null-ne$audit){break}
        Start-Sleep -Milliseconds 500
    }
    if($null-eq$audit){throw 'No local.intent audit record appeared within 3 minutes.'}
    if(-not [bool]$audit.ok){throw ('local.intent failed: '+($audit|ConvertTo-Json -Compress))}

    $Stage='verify-file-result'
    if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Source file missing: $SourcePath"}
    if(-not(Test-Path -LiteralPath $DestinationPath -PathType Leaf)){throw "Destination file missing: $DestinationPath"}

    $sourceText=Decode-SourceText ([IO.File]::ReadAllBytes($SourcePath))
    $firstLine=($sourceText -split "\r?\n",2)[0]
    $destText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($DestinationPath))

    if($destText -ne $firstLine){
        throw 'Destination UTF-8 text does not exactly match the source first line.'
    }

    $Stage='pass'
    Finish 'pass' 0 '' @{
        installed_before=[string]$before.tag
        installed_after=[string]$after.tag
        already_current=$alreadyCurrent
        icon_ok=$iconOk
        local_intent_ok=[bool]$audit.ok
        first_line_chars=$firstLine.Length
        destination_utf8_match=$true
    }
}catch{
    Finish 'fail' 31 $_.Exception.Message
}finally{
    if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',$OldSkip,'Process')
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    if($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){
        try{Start-Process -FilePath $AppExe|Out-Null}catch{}
    }
}
