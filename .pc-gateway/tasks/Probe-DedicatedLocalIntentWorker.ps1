[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ProjectPath = Join-Path $RepoRoot 'src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj'
$PlannerPath = Join-Path $RepoRoot 'src\ChatGptDesktopLocalBridge\ScheduledTasks\LocalIntentPlanner.cs'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$InstalledExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$SettingsPath = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\settings.json'
$LogRoot = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$SourcePath = 'D:\test\file.txt'
$ProcessName = 'ChatGptDesktopLocalBridge'
$TempRoot = Join-Path $env:TEMP ('bridge-dedicated-worker-e2e-' + [Guid]::NewGuid().ToString('N'))
$PublishRoot = Join-Path $TempRoot 'publish'
$SettingsBackup = Join-Path $TempRoot 'settings.before.json'
$DestinationPath = Join-Path $TempRoot 'first-line.txt'
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket = $null
$Stage = 'start'
$FirstWorkerId = $null
$SecondWorkerId = $null
$SettingsExisted = Test-Path -LiteralPath $SettingsPath -PathType Leaf
$TestStarted = [DateTimeOffset]::UtcNow

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $payload=[ordered]@{
        status=$Status
        error=$ErrorText
        exit_code=$Code
        stage=$Stage
    }
    foreach($key in $Extra.Keys){$payload[$key]=$Extra[$key]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 20 -Compress))
    exit $Code
}

function Stop-App {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 5
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId -Force -ErrorAction Stop)}catch{}
    }
    Start-Sleep -Seconds 5
}

function Wait-App([int]$TimeoutSeconds=60){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $items=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
        if($items.Count -gt 0){return $items[0]}
        Start-Sleep -Seconds 5
    }
    return $null
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=90){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 3)
            $target=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($target.Count -gt 0){return $target[0]}
        }catch{}
        Start-Sleep -Seconds 5
    }
    return $null
}

function Send-Cdp(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [int]$Id,
    [string]$Method,
    [hashtable]$Params=@{},
    [int]$TimeoutMs=30000
){
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $segment=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]$Socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while($true){
            $stream=New-Object IO.MemoryStream
            try{
                do{
                    $buffer=New-Object byte[] 65536
                    $bufferSegment=New-Object ArraySegment[byte] -ArgumentList (,$buffer)
                    $receive=$Socket.ReceiveAsync($bufferSegment,$cts.Token).GetAwaiter().GetResult()
                    if($receive.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP websocket closed.'}
                    $stream.Write($buffer,0,$receive.Count)
                }while(-not $receive.EndOfMessage)
                $message=([Text.Encoding]::UTF8.GetString($stream.ToArray())|ConvertFrom-Json)
                if($null-ne$message.PSObject.Properties['id'] -and [int]$message.id -eq $Id){return $message}
            }finally{$stream.Dispose()}
        }
    }catch{
        if($cts.IsCancellationRequested){throw "CDP timeout after $TimeoutMs ms for $Method."}
        throw
    }finally{$cts.Dispose()}
}

function Eval($Socket,[ref]$Id,[string]$Expression,[int]$TimeoutMs=30000){
    $response=Send-Cdp $Socket $Id.Value 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true} $TimeoutMs
    $Id.Value++
    if($null-ne$response.PSObject.Properties['error']){throw ('CDP error: '+($response.error|ConvertTo-Json -Depth 10 -Compress))}
    if($null-eq$response.PSObject.Properties['result'] -or $null-eq$response.result.PSObject.Properties['result']){throw 'CDP evaluation result missing.'}
    $inner=$response.result.result
    if($null-ne$response.result.PSObject.Properties['exceptionDetails']){throw ('CDP JS exception: '+($response.result.exceptionDetails|ConvertTo-Json -Depth 10 -Compress))}
    if($null-eq$inner.PSObject.Properties['value']){return $null}
    return $inner.value
}

function Get-UiTexts($Root){
    $values=New-Object System.Collections.ArrayList
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($element in $all){
        try{
            if($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text){
                $name=[string]$element.Current.Name
                if(-not [string]::IsNullOrWhiteSpace($name)){[void]$values.Add($name)}
            }
        }catch{}
    }
    return @($values|Select-Object -Unique)
}

function Wait-BridgeReady($Root,[int]$TimeoutSeconds=150){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $Root)
        if(@($texts|Where-Object{$_ -like 'Мост готов*' -or $_ -like 'Bridge ready*'}).Count -gt 0){return $true}
        Start-Sleep -Seconds 5
    }
    return $false
}

function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=90){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $health=Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
        if($null-ne$health -and [bool]$health.composerFound -and [bool]$health.nativeInputReady){return $health}
        Start-Sleep -Seconds 5
    }
    throw 'Local Bridge web adapter did not become ready.'
}

function Ensure-SafeEmptyComposer($Socket,[ref]$Id){
    $state=Eval $Socket $Id @'
(() => {
  const n=document.querySelector("#prompt-textarea,textarea[data-testid='prompt-textarea'],div[contenteditable='true'][data-testid='prompt-textarea'],div[contenteditable='true'][role='textbox']");
  if(!n)return {ok:false,reason:"not-found"};
  const text=(n.innerText||n.value||n.textContent||"").trim();
  if(!text)return {ok:true,empty:true};
  if(text.startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||text.startsWith("[[LOCAL_BRIDGE_RESULT_V1]]")){
    n.focus();
    if(typeof n.select==="function")n.select();
    else{const s=window.getSelection();const r=document.createRange();r.selectNodeContents(n);s.removeAllRanges();s.addRange(r);}
    return {ok:true,empty:false,service:true};
  }
  return {ok:false,reason:"user-draft-present",length:text.length};
})()
'@
    if(-not [bool]$state.ok){throw ('Composer is not safe for test input: '+($state|ConvertTo-Json -Compress))}
    if([bool]$state.empty){return}
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    [void](Send-Cdp $Socket $Id.Value 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$Id.Value++
    Start-Sleep -Seconds 5
}

function Send-ChatText($Socket,[ref]$Id,[string]$Text,[int]$TimeoutSeconds=90){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $prepared=$null
    while([DateTime]::UtcNow -lt $deadline){
        $prepared=Eval $Socket $Id 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
        if($null-ne$prepared -and [bool]$prepared.accepted){break}
        Start-Sleep -Seconds 5
    }
    if($null-eq$prepared -or -not [bool]$prepared.accepted){throw ('Chat preflight rejected: '+($prepared|ConvertTo-Json -Compress))}
    [void](Send-Cdp $Socket $Id.Value 'Input.insertText' @{text=$Text});$Id.Value++
    Start-Sleep -Seconds 5
    $expected=$Text|ConvertTo-Json -Compress
    $state=Eval $Socket $Id ('window.__localBridge?.nativeSendState?.('+$expected+') ?? null')
    if($null-eq$state -or -not [bool]$state.textMatches){throw 'Native input text was not accepted exactly.'}
    $submit=Eval $Socket $Id 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$submit -or -not [bool]$submit.accepted){throw ('Prompt submit rejected: '+($submit|ConvertTo-Json -Compress))}
}

function Try-ApprovePermission {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    while([DateTime]::UtcNow -lt $deadline){
        foreach($title in @('Разрешение Local Bridge','Local Bridge permission')){
            $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$title)
            $dialog=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
            if($null-eq$dialog){continue}
            foreach($name in @('Да','Yes')){
                $buttonCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
                $button=$dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$buttonCondition)
                if($null-ne$button){
                    $pattern=$null
                    if($button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
                        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                        return $true
                    }
                }
            }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Find-LatestAudit([string]$Tool,[DateTimeOffset]$StartedAfter){
    if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){return $null}
    $best=$null
    $bestTime=$StartedAfter
    foreach($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
        foreach($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)){
            if([string]::IsNullOrWhiteSpace($line)){continue}
            try{
                $row=$line|ConvertFrom-Json
                $timestamp=[DateTimeOffset]::Parse([string]$row.timestampUtc)
                if($timestamp -ge $StartedAfter -and $timestamp -ge $bestTime -and [string]$row.tool -eq $Tool){
                    $best=$row
                    $bestTime=$timestamp
                }
            }catch{}
        }
    }
    return $best
}

function Wait-Audit([string]$Tool,[DateTimeOffset]$StartedAfter,[int]$TimeoutSeconds=300){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $audit=Find-LatestAudit $Tool $StartedAfter
        if($null-ne$audit){return $audit}
        Start-Sleep -Seconds 5
    }
    return $null
}

function Read-WorkerState {
    if(-not(Test-Path -LiteralPath $SettingsPath -PathType Leaf)){return $null}
    $settings=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    return [ordered]@{
        id=if($null-ne$settings.PSObject.Properties['LocalIntentWorkerAutomationId']){[string]$settings.LocalIntentWorkerAutomationId}else{''}
        uncertain=if($null-ne$settings.PSObject.Properties['LocalIntentWorkerProvisioningUncertain']){[bool]$settings.LocalIntentWorkerProvisioningUncertain}else{$false}
    }
}

function Remove-VerifiedWorker($Socket,[ref]$Id,[string]$WorkerId){
    if([string]::IsNullOrWhiteSpace($WorkerId)){return $false}
    $workerArg=$WorkerId|ConvertTo-Json -Compress
    $expression=@"
(async () => {
  const id=$workerArg;
  const delay=ms=>new Promise(r=>setTimeout(r,ms));
  let last=null;
  async function req(path,options){
    if(last!==null){const elapsed=performance.now()-last;if(elapsed<5000)await delay(5000-elapsed);}
    try{
      const response=await fetch(path,options);
      const text=await response.text();
      last=performance.now();
      let json=null;try{json=text?JSON.parse(text):null}catch{}
      return {ok:response.ok,status:response.status,text,json,error:null};
    }catch(error){last=performance.now();return {ok:false,status:0,text:'',json:null,error:String(error)};}
  }
  const auth=await req('/api/auth/session',{method:'GET',credentials:'include',cache:'no-store',redirect:'error',headers:{accept:'application/json'}});
  if(!auth.ok)return {ok:false,stage:'auth',status:auth.status,error:auth.error};
  const token=typeof auth.json?.accessToken==='string'?auth.json.accessToken:'';
  const accountId=typeof auth.json?.account?.id==='string'?auth.json.account.id:'';
  if(!token)return {ok:false,stage:'auth-token'};
  const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+token};
  if(accountId)headers['chatgpt-account-id']=accountId;
  const detail=await req('/backend-api/automation/'+encodeURIComponent(id),{method:'GET',credentials:'include',redirect:'follow',headers});
  if(detail.status===404)return {ok:true,removed:true,alreadyMissing:true};
  if(!detail.ok||!detail.json)return {ok:false,stage:'read',status:detail.status,error:detail.error};
  if(String(detail.json.title||'')!=='Local Bridge · служебный планировщик')return {ok:false,stage:'identity-title'};
  if(typeof detail.json.prompt!=='string'||!detail.json.prompt.includes('LOCAL BRIDGE SERVICE WORKER V1'))return {ok:false,stage:'identity-marker'};
  const removeHeaders={...headers,'content-type':'application/json'};
  const removed=await req('/backend-api/automations/remove',{method:'POST',credentials:'include',redirect:'follow',headers:removeHeaders,body:JSON.stringify({automation_id:id})});
  return {ok:removed.ok,removed:removed.ok,status:removed.status,error:removed.error};
})()
"@
    $result=Eval $Socket $Id $expression 60000
    if($null-eq$result -or -not [bool]$result.ok){throw ('Verified worker removal failed: '+($result|ConvertTo-Json -Depth 10 -Compress))}
    return $true
}

function Decode-SourceText([byte[]]$Bytes){
    if($Bytes.Length -ge 3 -and $Bytes[0]-eq 0xEF -and $Bytes[1]-eq 0xBB -and $Bytes[2]-eq 0xBF){
        return [Text.Encoding]::UTF8.GetString($Bytes,3,$Bytes.Length-3)
    }
    try{
        $utf8=New-Object Text.UTF8Encoding -ArgumentList @($false,$true)
        return $utf8.GetString($Bytes)
    }catch{
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
        return [Text.Encoding]::GetEncoding(1251).GetString($Bytes)
    }
}

function Prepare-TestSettings {
    $dir=Split-Path -Parent $SettingsPath
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    if($SettingsExisted){
        Copy-Item -LiteralPath $SettingsPath -Destination $SettingsBackup -Force
        $settings=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    }else{
        $settings=[pscustomobject]@{}
    }

    function Set-Prop($obj,[string]$Name,$Value){
        if($null-ne$obj.PSObject.Properties[$Name]){$obj.$Name=$Value}
        else{$obj|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}
    }

    Set-Prop $settings 'AutoInitializeBridge' $true
    Set-Prop $settings 'TabUrls' @('https://chatgpt.com/')
    Set-Prop $settings 'SelectedTabIndex' 0
    Set-Prop $settings 'LocalIntentWorkerAutomationId' $null
    Set-Prop $settings 'LocalIntentWorkerProvisioningUncertain' $false
    $settings|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

try{
    $Stage='verify-source'
    if(-not(Test-Path -LiteralPath $ProjectPath -PathType Leaf)){throw 'Project file missing from gateway checkout.'}
    if(-not(Test-Path -LiteralPath $PlannerPath -PathType Leaf)){throw 'LocalIntentPlanner.cs missing from gateway checkout.'}
    if(Select-String -LiteralPath $PlannerPath -SimpleMatch '/backend-api/automations?filter=paused' -Quiet){
        throw 'Planner still contains user paused-task enumeration.'
    }
    if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Source test file missing: $SourcePath"}

    $Stage='prepare-settings'
    New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
    Prepare-TestSettings

    $Stage='build-feature'
    & dotnet.exe publish $ProjectPath --configuration Release --runtime win-x64 --self-contained true --output $PublishRoot
    if($LASTEXITCODE -ne 0){throw "dotnet publish failed with exit code $LASTEXITCODE."}
    $FeatureExe=Join-Path $PublishRoot 'ChatGptDesktopLocalBridge.exe'
    if(-not(Test-Path -LiteralPath $FeatureExe -PathType Leaf)){throw 'Feature executable was not produced.'}

    $Stage='start-feature'
    Stop-App
    $port=Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $FeatureExe|Out-Null
    $app=Wait-App 60
    if($null-eq$app){throw 'Feature application window did not appear.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if($null-eq$root){throw 'UI Automation root unavailable.'}

    $Stage='connect-chat'
    $target=Wait-Target $port 90
    if($null-eq$target){throw 'ChatGPT WebView target unavailable.'}
    $Socket=New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1
    [void](Wait-Adapter $Socket ([ref]$id) 90)

    [void](Send-Cdp $Socket $id 'Network.enable' @{});$id++
    Start-Sleep -Seconds 5
    [void](Send-Cdp $Socket $id 'Network.setBlockedURLs' @{urls=@('*backend-api/automations?filter=paused*')});$id++

    $Stage='wait-bridge-ready'
    if(-not(Wait-BridgeReady $root 150)){throw 'Automatic Local Bridge READY timeout.'}
    Ensure-SafeEmptyComposer $Socket ([ref]$id)
    Start-Sleep -Seconds 5

    $Stage='first-local-intent'
    $firstStarted=[DateTimeOffset]::UtcNow
    $command1="Use the Local Bridge local.intent tool to read the first line of $SourcePath and write it to $DestinationPath."
    Send-ChatText $Socket ([ref]$id) $command1 90
    $permission1=[Threading.Tasks.Task]::Run([Action]{[void](Try-ApprovePermission)})
    $audit1=Wait-Audit 'local.intent' $firstStarted 300
    if($null-eq$audit1){throw 'First local.intent audit record did not appear.'}
    if(-not[bool]$audit1.ok){throw ('First local.intent failed: '+($audit1|ConvertTo-Json -Compress))}
    if(-not(Test-Path -LiteralPath $DestinationPath -PathType Leaf)){throw 'First local.intent did not create the destination file.'}

    $sourceText=Decode-SourceText ([IO.File]::ReadAllBytes($SourcePath))
    $firstLine=($sourceText -split "\r?\n",2)[0]
    $destText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($DestinationPath))
    if($destText -ne $firstLine){throw 'First local.intent destination does not match source first line.'}

    $worker1=Read-WorkerState
    if($null-eq$worker1 -or [string]::IsNullOrWhiteSpace([string]$worker1.id)){throw 'Dedicated worker id was not persisted after first run.'}
    if([bool]$worker1.uncertain){throw 'Dedicated worker remained in uncertain provisioning state after first run.'}
    $FirstWorkerId=[string]$worker1.id

    $Stage='delete-first-worker'
    Start-Sleep -Seconds 6
    [void](Remove-VerifiedWorker $Socket ([ref]$id) $FirstWorkerId)
    Start-Sleep -Seconds 6

    $Stage='second-local-intent-recovery'
    Ensure-SafeEmptyComposer $Socket ([ref]$id)
    $secondStarted=[DateTimeOffset]::UtcNow
    $command2="Use the Local Bridge local.intent tool to read $SourcePath."
    Send-ChatText $Socket ([ref]$id) $command2 90
    $permission2=[Threading.Tasks.Task]::Run([Action]{[void](Try-ApprovePermission)})
    $audit2=Wait-Audit 'local.intent' $secondStarted 300
    if($null-eq$audit2){throw 'Second local.intent audit record did not appear after worker deletion.'}
    if(-not[bool]$audit2.ok){throw ('Second local.intent failed after worker deletion: '+($audit2|ConvertTo-Json -Compress))}

    $worker2=Read-WorkerState
    if($null-eq$worker2 -or [string]::IsNullOrWhiteSpace([string]$worker2.id)){throw 'Replacement dedicated worker id was not persisted.'}
    if([bool]$worker2.uncertain){throw 'Replacement dedicated worker remained uncertain.'}
    $SecondWorkerId=[string]$worker2.id
    if($SecondWorkerId -eq $FirstWorkerId){throw 'Worker id did not change after confirmed deletion and recovery.'}

    $Stage='cleanup-test-worker'
    Start-Sleep -Seconds 6
    [void](Remove-VerifiedWorker $Socket ([ref]$id) $SecondWorkerId)

    $Stage='pass'
    Finish 'pass' 0 '' @{
        build_ok=$true
        paused_task_endpoint_blocked=$true
        first_local_intent_ok=$true
        file_result_ok=$true
        first_worker_created=$true
        worker_deleted=$true
        recovery_local_intent_ok=$true
        replacement_worker_created=$true
        first_worker_prefix=$FirstWorkerId.Substring(0,[Math]::Min(8,$FirstWorkerId.Length))
        second_worker_prefix=$SecondWorkerId.Substring(0,[Math]::Min(8,$SecondWorkerId.Length))
    }
}catch{
    Finish 'fail' 31 $_.Exception.Message @{
        first_worker_prefix=if([string]::IsNullOrWhiteSpace($FirstWorkerId)){''}else{$FirstWorkerId.Substring(0,[Math]::Min(8,$FirstWorkerId.Length))}
        second_worker_prefix=if([string]::IsNullOrWhiteSpace($SecondWorkerId)){''}else{$SecondWorkerId.Substring(0,[Math]::Min(8,$SecondWorkerId.Length))}
    }
}finally{
    if($null-ne$Socket){
        try{
            $state=Read-WorkerState
            if($null-ne$state -and -not[string]::IsNullOrWhiteSpace([string]$state.id)){
                Start-Sleep -Seconds 6
                try{[void](Remove-VerifiedWorker $Socket ([ref]$id) ([string]$state.id))}catch{}
            }
        }catch{}
        try{$Socket.Dispose()}catch{}
    }

    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')

    try{
        if($SettingsExisted -and (Test-Path -LiteralPath $SettingsBackup -PathType Leaf)){
            Copy-Item -LiteralPath $SettingsBackup -Destination $SettingsPath -Force
        }elseif(-not$SettingsExisted -and (Test-Path -LiteralPath $SettingsPath -PathType Leaf)){
            Remove-Item -LiteralPath $SettingsPath -Force
        }
    }catch{}

    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

    if($WasRunning -and (Test-Path -LiteralPath $InstalledExe -PathType Leaf)){
        try{Start-Process -FilePath $InstalledExe|Out-Null}catch{}
    }
}
