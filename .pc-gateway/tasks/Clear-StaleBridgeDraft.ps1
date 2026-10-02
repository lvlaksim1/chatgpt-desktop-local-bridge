[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

function Write-Result([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

function Stop-App {
    foreach($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 1
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=40){
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

$appExe=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
if(-not(Test-Path -LiteralPath $appExe -PathType Leaf)){Write-Result 'fail' 10 'Installed app missing.'}

$wasRunning=@(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue).Count -gt 0
$oldArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$port=Get-Random -Minimum 9400 -Maximum 9999
$socket=$null

try{
    Stop-App
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $appExe|Out-Null
    $target=Wait-Target $port 40
    if($null-eq$target){throw 'WebView2 target did not appear.'}

    $socket=New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1

    $inspect=@'
(() => {
  const c=document.querySelector("#prompt-textarea")||
          document.querySelector("textarea[data-testid='prompt-textarea']")||
          document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']")||
          document.querySelector("div[contenteditable='true'][role='textbox']");
  if(!c) return {ready:false,reason:"composer-not-found"};
  const text=(c.value||c.innerText||c.textContent||"").replace(/\u200B/g,"");
  return {
    ready:true,
    length:text.length,
    empty:text.trim().length===0,
    bridgeOwned:text.trim().startsWith("[[LOCAL_BRIDGE_BOOTSTRAP_V1]]")||
                text.trim().startsWith("[[LOCAL_BRIDGE_RESULT_V1]]")
  };
})()
'@

    $state=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    while([DateTime]::UtcNow -lt $deadline){
        $state=Eval $socket ([ref]$id) $inspect
        if($null-ne$state -and [bool]$state.ready){break}
        Start-Sleep -Milliseconds 500
    }
    if($null-eq$state -or -not [bool]$state.ready){throw 'Composer did not become ready.'}

    if([bool]$state.empty){
        Write-Result 'success' 0 '' @{already_empty=$true;cleared=$false}
    }
    if(-not [bool]$state.bridgeOwned){
        Write-Result 'blocked' 20 'Composer contains a non-bridge draft; refusing to modify it.' @{composer_length=[int]$state.length}
    }

    $select=@'
(() => {
  const c=document.querySelector("#prompt-textarea")||
          document.querySelector("textarea[data-testid='prompt-textarea']")||
          document.querySelector("div[contenteditable='true'][data-testid='prompt-textarea']")||
          document.querySelector("div[contenteditable='true'][role='textbox']");
  if(!c) return false;
  c.focus();
  if(c instanceof HTMLTextAreaElement||c instanceof HTMLInputElement){
    c.select();
  }else{
    const s=getSelection();
    const r=document.createRange();
    r.selectNodeContents(c);
    s.removeAllRanges();
    s.addRange(r);
  }
  return true;
})()
'@
    if(-not [bool](Eval $socket ([ref]$id) $select)){throw 'Could not select bridge-owned draft.'}

    [void](Send-Cdp $socket $id 'Input.dispatchKeyEvent' @{type='keyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$id++
    [void](Send-Cdp $socket $id 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8;nativeVirtualKeyCode=8});$id++

    Start-Sleep -Milliseconds 500
    $after=Eval $socket ([ref]$id) $inspect
    if($null-eq$after -or -not [bool]$after.empty){
        throw ('Bridge draft clear was not confirmed. remaining_length='+[string]$after.length)
    }

    Write-Result 'success' 0 '' @{already_empty=$false;cleared=$true;previous_length=[int]$state.length}
}catch{
    Write-Result 'fail' 31 $_.Exception.Message
}finally{
    if($null-ne$socket){try{$socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldArgs,'Process')
    if($wasRunning -and (Test-Path -LiteralPath $appExe -PathType Leaf)){
        try{Start-Process -FilePath $appExe|Out-Null}catch{}
    }
}