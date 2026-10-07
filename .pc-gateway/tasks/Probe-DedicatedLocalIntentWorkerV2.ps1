[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Project=Join-Path $RepoRoot 'src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj'
$Planner=Join-Path $RepoRoot 'src\ChatGptDesktopLocalBridge\ScheduledTasks\LocalIntentPlanner.cs'
$InstalledExe=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$Settings=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\settings.json'
$Logs=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'
$Source='D:\test\file.txt'
$ProcessName='ChatGptDesktopLocalBridge'
$Temp=Join-Path $env:TEMP ('lb-worker-e2e-'+[Guid]::NewGuid().ToString('N'))
$Publish=Join-Path $Temp 'publish'
$Backup=Join-Path $Temp 'settings.before.json'
$Destination=Join-Path $Temp 'first-line.txt'
$OldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$WasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$HadSettings=Test-Path -LiteralPath $Settings -PathType Leaf
$Socket=$null
$CdpId=1
$Stage='start'
$Worker1=''
$Worker2=''

function U8([string]$Base64){
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function Write-Result([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage}
    foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $p|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($p|ConvertTo-Json -Depth 20 -Compress))
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
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 5
}

function Wait-App([int]$Seconds){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $until){
        $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
        if($p.Count -gt 0){return $p[0]}
        Start-Sleep -Seconds 5
    }
    $null
}

function Wait-Target([int]$Port,[int]$Seconds){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $until){
        try{
            $rows=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 3)
            $t=@($rows|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($t.Count -gt 0){return $t[0]}
        }catch{}
        Start-Sleep -Seconds 5
    }
    $null
}

function Cdp([string]$Method,[hashtable]$Params=@{},[int]$TimeoutMs=30000){
    $id=$script:CdpId
    $script:CdpId++
    $json=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try{
        [void]$script:Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        while($true){
            $ms=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $rxseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $rx=$script:Socket.ReceiveAsync($rxseg,$cts.Token).GetAwaiter().GetResult()
                    if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP socket closed.'}
                    $ms.Write($buf,0,$rx.Count)
                }while(-not $rx.EndOfMessage)
                $msg=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
                if($null-ne$msg.PSObject.Properties['id'] -and [int]$msg.id -eq $id){return $msg}
            }finally{$ms.Dispose()}
        }
    }catch{
        if($cts.IsCancellationRequested){throw "CDP timeout for $Method."}
        throw
    }finally{$cts.Dispose()}
}

function Eval([string]$Expression,[int]$TimeoutMs=30000){
    $r=Cdp 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true} $TimeoutMs
    if($null-ne$r.PSObject.Properties['error']){throw ('CDP error: '+($r.error|ConvertTo-Json -Compress))}
    if($null-ne$r.result.PSObject.Properties['exceptionDetails']){throw ('CDP JS exception: '+($r.result.exceptionDetails|ConvertTo-Json -Compress))}
    if($null-eq$r.result.PSObject.Properties['result']){throw 'CDP result missing.'}
    $v=$r.result.result
    if($null-eq$v.PSObject.Properties['value']){return $null}
    $v.value
}

function Wait-Adapter([int]$Seconds){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $until){
        $h=Eval 'window.__localBridge?.health?.() ?? null'
        if($null-ne$h -and [bool]$h.composerFound -and [bool]$h.nativeInputReady){return}
        Start-Sleep -Seconds 5
    }
    throw 'Bridge adapter not ready.'
}

function Ui-Texts($Root){
    $out=New-Object System.Collections.ArrayList
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($e in $all){
        try{
            if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text){
                $n=[string]$e.Current.Name
                if(-not[string]::IsNullOrWhiteSpace($n)){[void]$out.Add($n)}
            }
        }catch{}
    }
    @($out|Select-Object -Unique)
}

function Wait-BridgeReady($Root,[int]$Seconds){
    $ru=U8 '0JzQvtGB0YIg0LPQvtGC0L7Qsg=='
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $until){
        $texts=@(Ui-Texts $Root)
        if(@($texts|Where-Object{$_ -like ($ru+'*') -or $_ -like 'Bridge ready*'}).Count -gt 0){return}
        Start-Sleep -Seconds 5
    }
    throw 'Automatic bridge READY timeout.'
}

function Safe-Composer {
    $s=Eval @'
(() => {
  const n=document.querySelector("#prompt-textarea,textarea[data-testid='prompt-textarea'],div[contenteditable='true'][data-testid='prompt-textarea'],div[contenteditable='true'][role='textbox']");
  if(!n)return {ok:false,reason:"not-found"};
  const t=(n.innerText||n.value||n.textContent||"").trim();
  if(!t)return {ok:true,empty:true};
  if(t.startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||t.startsWith("[[LOCAL_BRIDGE_RESULT_V1]]")){
    n.focus();
    if(typeof n.select==="function")n.select();
    else{const s=window.getSelection();const r=document.createRange();r.selectNodeContents(n);s.removeAllRanges();s.addRange(r);}
    return {ok:true,empty:false,service:true};
  }
  return {ok:false,reason:"user-draft-present",length:t.length};
})()
'@
    if(-not[bool]$s.ok){throw ('Composer blocked: '+($s|ConvertTo-Json -Compress))}
    if([bool]$s.empty){return}
    [void](Cdp 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8})
    [void](Cdp 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8})
    Start-Sleep -Seconds 5
}

function Send-Text([string]$Text,[int]$Seconds=90){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    $p=$null
    while([DateTime]::UtcNow -lt $until){
        $p=Eval 'window.__localBridge?.prepareNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
        if($null-ne$p -and [bool]$p.accepted){break}
        Start-Sleep -Seconds 5
    }
    if($null-eq$p -or -not[bool]$p.accepted){throw ('Send preflight failed: '+($p|ConvertTo-Json -Compress))}
    [void](Cdp 'Input.insertText' @{text=$Text})
    Start-Sleep -Seconds 5
    $arg=$Text|ConvertTo-Json -Compress
    $state=Eval ('window.__localBridge?.nativeSendState?.('+$arg+') ?? null')
    if($null-eq$state -or -not[bool]$state.textMatches){throw 'Input text mismatch.'}
    $submit=Eval 'window.__localBridge?.submitNativeSend?.() ?? {accepted:false,reason:"adapter-not-ready"}'
    if($null-eq$submit -or -not[bool]$submit.accepted){throw ('Submit failed: '+($submit|ConvertTo-Json -Compress))}
}

function Approve-Permission {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $ruTitle=U8 '0KDQsNC30YDQtdGI0LXQvdC40LUgTG9jYWwgQnJpZGdl'
    $ruYes=U8 '0JTQsA=='
    $until=[DateTime]::UtcNow.AddSeconds(120)
    while([DateTime]::UtcNow -lt $until){
        foreach($title in @($ruTitle,'Local Bridge permission')){
            $c=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$title)
            $dialog=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$c)
            if($null-eq$dialog){continue}
            foreach($name in @($ruYes,'Yes')){
                $bc=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
                $button=$dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$bc)
                if($null-ne$button){
                    $pattern=$null
                    if($button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
                        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                        return
                    }
                }
            }
        }
        Start-Sleep -Seconds 5
    }
}

function Latest-Audit([DateTimeOffset]$After){
    $best=$null
    $time=$After
    if(-not(Test-Path -LiteralPath $Logs -PathType Container)){return $null}
    foreach($f in @(Get-ChildItem -LiteralPath $Logs -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
        foreach($line in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)){
            try{
                if([string]::IsNullOrWhiteSpace($line)){continue}
                $r=$line|ConvertFrom-Json
                $ts=[DateTimeOffset]::Parse([string]$r.timestampUtc)
                if($ts -ge $After -and $ts -ge $time -and [string]$r.tool -eq 'local.intent'){$best=$r;$time=$ts}
            }catch{}
        }
    }
    $best
}

function Wait-Audit([DateTimeOffset]$After,[int]$Seconds=300){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow -lt $until){
        $a=Latest-Audit $After
        if($null-ne$a){return $a}
        Start-Sleep -Seconds 5
    }
    $null
}

function Worker-State {
    if(-not(Test-Path -LiteralPath $Settings -PathType Leaf)){return $null}
    $s=Get-Content -LiteralPath $Settings -Raw -Encoding UTF8|ConvertFrom-Json
    [pscustomobject]@{
        id=if($null-ne$s.PSObject.Properties['LocalIntentWorkerAutomationId']){[string]$s.LocalIntentWorkerAutomationId}else{''}
        uncertain=if($null-ne$s.PSObject.Properties['LocalIntentWorkerProvisioningUncertain']){[bool]$s.LocalIntentWorkerProvisioningUncertain}else{$false}
    }
}

function Remove-Worker([string]$WorkerId){
    if([string]::IsNullOrWhiteSpace($WorkerId)){return}
    $idArg=$WorkerId|ConvertTo-Json -Compress
    $js=@"
(async()=>{
 const id=$idArg,delay=ms=>new Promise(r=>setTimeout(r,ms));let last=null;
 async function q(path,options){
  if(last!==null){const e=performance.now()-last;if(e<5000)await delay(5000-e);}
  try{const r=await fetch(path,options),t=await r.text();last=performance.now();let j=null;try{j=t?JSON.parse(t):null}catch{};return{ok:r.ok,status:r.status,json:j,error:null};}
  catch(error){last=performance.now();return{ok:false,status:0,json:null,error:String(error)};}
 }
 const a=await q('/api/auth/session',{method:'GET',credentials:'include',cache:'no-store',redirect:'error',headers:{accept:'application/json'}});
 if(!a.ok)return{ok:false,stage:'auth',status:a.status,error:a.error};
 const token=typeof a.json?.accessToken==='string'?a.json.accessToken:'',accountId=typeof a.json?.account?.id==='string'?a.json.account.id:'';
 if(!token)return{ok:false,stage:'token'};
 const h={accept:'application/json, text/plain, */*',authorization:'Bearer '+token};if(accountId)h['chatgpt-account-id']=accountId;
 const d=await q('/backend-api/automation/'+encodeURIComponent(id),{method:'GET',credentials:'include',redirect:'follow',headers:h});
 if(d.status===404)return{ok:true,alreadyMissing:true};
 if(!d.ok||!d.json)return{ok:false,stage:'read',status:d.status,error:d.error};
 if(typeof d.json.prompt!=='string'||!d.json.prompt.includes('LOCAL BRIDGE SERVICE WORKER V1'))return{ok:false,stage:'identity'};
 const rh={...h,'content-type':'application/json'};
 const x=await q('/backend-api/automations/remove',{method:'POST',credentials:'include',redirect:'follow',headers:rh,body:JSON.stringify({automation_id:id})});
 return{ok:x.ok,status:x.status,error:x.error};
})()
"@
    $r=Eval $js 60000
    if($null-eq$r -or -not[bool]$r.ok){throw ('Worker cleanup failed: '+($r|ConvertTo-Json -Compress))}
}

function Decode-Source([byte[]]$Bytes){
    if($Bytes.Length -ge 3 -and $Bytes[0]-eq 0xEF -and $Bytes[1]-eq 0xBB -and $Bytes[2]-eq 0xBF){return [Text.Encoding]::UTF8.GetString($Bytes,3,$Bytes.Length-3)}
    try{$u=New-Object Text.UTF8Encoding -ArgumentList @($false,$true);return $u.GetString($Bytes)}
    catch{return [Text.Encoding]::GetEncoding(1251).GetString($Bytes)}
}

function Prepare-Settings {
    $dir=Split-Path -Parent $Settings
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    if($HadSettings){Copy-Item $Settings $Backup -Force;$s=Get-Content $Settings -Raw -Encoding UTF8|ConvertFrom-Json}else{$s=[pscustomobject]@{}}
    function Put($o,[string]$n,$v){if($null-ne$o.PSObject.Properties[$n]){$o.$n=$v}else{$o|Add-Member -NotePropertyName $n -NotePropertyValue $v}}
    Put $s 'AutoInitializeBridge' $true
    Put $s 'TabUrls' @('https://chatgpt.com/')
    Put $s 'SelectedTabIndex' 0
    Put $s 'LocalIntentWorkerAutomationId' $null
    Put $s 'LocalIntentWorkerProvisioningUncertain' $false
    $s|ConvertTo-Json -Depth 20|Set-Content $Settings -Encoding UTF8
}

try{
    $Stage='verify-source'
    if(-not(Test-Path $Project)){throw 'Project missing.'}
    if(Select-String -LiteralPath $Planner -SimpleMatch '/backend-api/automations?filter=paused' -Quiet){throw 'Paused-user-task enumeration still present.'}
    if(-not(Test-Path $Source)){throw "Source file missing: $Source"}

    $Stage='prepare'
    New-Item -ItemType Directory -Force -Path $Temp|Out-Null
    Prepare-Settings

    $Stage='build'
    & dotnet.exe publish $Project --configuration Release --runtime win-x64 --self-contained true --output $Publish
    if($LASTEXITCODE -ne 0){throw "Publish failed: $LASTEXITCODE"}
    $FeatureExe=Join-Path $Publish 'ChatGptDesktopLocalBridge.exe'
    if(-not(Test-Path $FeatureExe)){throw 'Feature executable missing.'}

    $Stage='start'
    Stop-App
    $port=Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process $FeatureExe|Out-Null
    $app=Wait-App 60
    if($null-eq$app){throw 'Feature window missing.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if($null-eq$root){throw 'UI Automation root missing.'}

    $Stage='connect'
    $target=Wait-Target $port 90
    if($null-eq$target){throw 'WebView target missing.'}
    $Socket=New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    Wait-Adapter 90

    [void](Cdp 'Network.enable' @{})
    Start-Sleep -Seconds 5
    [void](Cdp 'Network.setBlockedURLs' @{urls=@('*backend-api/automations?filter=paused*')})

    $Stage='bridge-ready'
    Wait-BridgeReady $root 150
    Safe-Composer
    Start-Sleep -Seconds 5

    $Stage='first-run'
    $t1=[DateTimeOffset]::UtcNow
    Send-Text ("Use the Local Bridge local.intent tool to read the first line of "+$Source+" and write it to "+$Destination+".")
    $p1=[System.Threading.Tasks.Task]::Run([Action]{Approve-Permission})
    $a1=Wait-Audit $t1 300
    if($null-eq$a1){throw 'First local.intent audit timeout.'}
    if(-not[bool]$a1.ok){throw ('First local.intent failed: '+($a1|ConvertTo-Json -Compress))}
    if(-not(Test-Path $Destination)){throw 'Destination missing.'}
    $sourceText=Decode-Source ([IO.File]::ReadAllBytes($Source))
    $first=($sourceText -split "\r?\n",2)[0]
    $dest=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Destination))
    if($dest -ne $first){throw 'Destination mismatch.'}

    $s1=Worker-State
    if($null-eq$s1 -or [string]::IsNullOrWhiteSpace($s1.id)){throw 'First worker id missing.'}
    if([bool]$s1.uncertain){throw 'First worker is uncertain.'}
    $Worker1=$s1.id

    $Stage='delete-worker'
    Start-Sleep -Seconds 6
    Remove-Worker $Worker1
    Start-Sleep -Seconds 6

    $Stage='recovery-run'
    Safe-Composer
    $t2=[DateTimeOffset]::UtcNow
    Send-Text ("Use the Local Bridge local.intent tool to read "+$Source+".")
    $p2=[System.Threading.Tasks.Task]::Run([Action]{Approve-Permission})
    $a2=Wait-Audit $t2 300
    if($null-eq$a2){throw 'Recovery local.intent audit timeout.'}
    if(-not[bool]$a2.ok){throw ('Recovery local.intent failed: '+($a2|ConvertTo-Json -Compress))}
    $s2=Worker-State
    if($null-eq$s2 -or [string]::IsNullOrWhiteSpace($s2.id)){throw 'Replacement worker id missing.'}
    if([bool]$s2.uncertain){throw 'Replacement worker is uncertain.'}
    $Worker2=$s2.id
    if($Worker2 -eq $Worker1){throw 'Worker id did not change after deletion.'}

    $Stage='cleanup-worker'
    Start-Sleep -Seconds 6
    Remove-Worker $Worker2

    $Stage='pass'
    Write-Result 'pass' 0 '' @{
        source_has_no_paused_task_enumeration=$true
        paused_endpoint_blocked=$true
        first_local_intent_ok=$true
        file_result_ok=$true
        deleted_worker_recovered=$true
        first_worker_prefix=$Worker1.Substring(0,[Math]::Min(8,$Worker1.Length))
        second_worker_prefix=$Worker2.Substring(0,[Math]::Min(8,$Worker2.Length))
    }
}catch{
    Write-Result 'fail' 31 $_.Exception.Message @{
        first_worker_prefix=if([string]::IsNullOrWhiteSpace($Worker1)){''}else{$Worker1.Substring(0,[Math]::Min(8,$Worker1.Length))}
        second_worker_prefix=if([string]::IsNullOrWhiteSpace($Worker2)){''}else{$Worker2.Substring(0,[Math]::Min(8,$Worker2.Length))}
    }
}finally{
    if($null-ne$Socket){
        try{$s=Worker-State;if($null-ne$s -and -not[string]::IsNullOrWhiteSpace($s.id)){Start-Sleep -Seconds 6;Remove-Worker $s.id}}catch{}
        try{$Socket.Dispose()}catch{}
    }
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    try{
        if($HadSettings -and (Test-Path $Backup)){Copy-Item $Backup $Settings -Force}
        elseif(-not$HadSettings -and (Test-Path $Settings)){Remove-Item $Settings -Force}
    }catch{}
    Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
    if($WasRunning -and (Test-Path $InstalledExe)){try{Start-Process $InstalledExe|Out-Null}catch{}}
}
