[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$GapSeconds = 5
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ProcessName = 'ChatGptDesktopLocalBridge'
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$Socket = $null
$NextId = 1

function Finish([string]$Status,[int]$Code,[string]$ErrorText,[hashtable]$Extra) {
    $o=[ordered]@{status=$Status;exit_code=$Code;error=$ErrorText;network_min_gap_seconds=$GapSeconds}
    foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $o|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $Code
}
function Stop-App {
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
function Stop-WebViews {
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($item in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop}catch{}
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
function Wait-Target([int]$Port,[int]$TimeoutSeconds=60){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        try{
            $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
            $t=@($items|Where-Object{$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and $_.webSocketDebuggerUrl}|Select-Object -First 1)
            if($t.Count -gt 0){return $t[0]}
        }catch{}
        Start-Sleep -Seconds $GapSeconds
    }
    return $null
}
function Send-Cdp([string]$Method,[hashtable]$Params){
    $id=$script:NextId;$script:NextId++
    $json=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $seg=New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(180000)
    try{
        [void]($script:Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
        while($true){
            $mem=New-Object IO.MemoryStream
            try{
                do{
                    $buf=New-Object byte[] 65536
                    $bseg=New-Object ArraySegment[byte] -ArgumentList (, $buf)
                    $rx=$script:Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
                    if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'cdp_closed'}
                    $mem.Write($buf,0,$rx.Count)
                }while(-not $rx.EndOfMessage)
                $m=([Text.Encoding]::UTF8.GetString($mem.ToArray())|ConvertFrom-Json)
                if($null -ne $m.PSObject.Properties['id'] -and [int]$m.id -eq $id){return $m}
            }finally{$mem.Dispose()}
        }
    }finally{$cts.Dispose()}
}
function Eval([string]$Expression){
    $r=Send-Cdp -Method 'Runtime.evaluate' -Params @{expression=$Expression;returnByValue=$true;awaitPromise=$true}
    if($null -ne $r.PSObject.Properties['error']){throw('cdp_error:'+($r.error|ConvertTo-Json -Compress))}
    if($null -ne $r.result.PSObject.Properties['exceptionDetails']){throw('js_exception:'+($r.result.exceptionDetails|ConvertTo-Json -Depth 5 -Compress))}
    return $r.result.result.value
}

try{
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'installed_app_missing'}
    Stop-App
    Stop-WebViews
    $port=Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null
    if($null -eq (Wait-App)){throw 'app_window_missing'}
    $target=Wait-Target -Port $port
    if($null -eq $target){throw 'cdp_target_missing'}
    $ws=[string]$target.webSocketDebuggerUrl
    $script:Socket=New-Object Net.WebSockets.ClientWebSocket
    $script:Socket.ConnectAsync([Uri]$ws,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    Start-Sleep -Seconds 5
    $before=Eval -Expression "({url:location.href,title:document.title,ready:document.readyState})"
    Start-Sleep -Seconds $GapSeconds
    [void](Eval -Expression "location.href='https://chatgpt.com/tasks'; 'navigating'")
    Start-Sleep -Seconds 15
    $observation=Eval -Expression @'
(() => {
  const files=Array.from(document.querySelectorAll('input[type="file"]')).slice(0,20).map((e,i)=>({index:i,accept:e.accept||null,multiple:!!e.multiple,aria:e.getAttribute('aria-label'),testid:e.getAttribute('data-testid')}));
  const buttons=Array.from(document.querySelectorAll('button')).slice(0,250).map((e,i)=>({index:i,text:String(e.innerText||'').trim().slice(0,120),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),testid:e.getAttribute('data-testid')}));
  const links=Array.from(document.querySelectorAll('a')).slice(0,250).map((e,i)=>({index:i,text:String(e.innerText||'').trim().slice(0,120),href:e.href||null,aria:e.getAttribute('aria-label')}));
  return {url:location.href,title:document.title,ready:document.readyState,file_inputs:files,buttons:buttons,links:links,body_text:String(document.body&&document.body.innerText||'').slice(0,16000)};
})()
'@
    Finish -Status 'pass' -Code 0 -ErrorText '' -Extra @{before=$before;observation=$observation}
}catch{
    Finish -Status 'fail' -Code 40 -ErrorText $_.Exception.Message -Extra @{}
}finally{
    if($null -ne $script:Socket){try{$script:Socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    try{Stop-WebViews}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
}
