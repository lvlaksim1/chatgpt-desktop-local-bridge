[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProcessName = 'ChatGptDesktopLocalBridge'
$AppExe = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$WasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$Socket = $null
$Stage = 'init'

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}) {
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code;stage=$Stage}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
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
    Start-Sleep -Seconds 2
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId -as [int]) -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 1
}

function Wait-Target([int]$Port,[int]$TimeoutSeconds=60){
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
    if($null-ne$r.result.PSObject.Properties['exceptionDetails']){throw ('JS exception: '+($r.result.exceptionDetails|ConvertTo-Json -Compress))}
    return $r.result.result.value
}

try{
    $Stage='start-app'
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'Installed application is missing.'}

    $port=Get-Random -Minimum 9400 -Maximum 9999
    Stop-App
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe|Out-Null

    $Stage='connect'
    $target=Wait-Target $port 60
    if($null-eq$target){throw 'ChatGPT WebView target unavailable.'}

    $Socket=New-Object Net.WebSockets.ClientWebSocket
    $Socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $id=1

    $Stage='navigate-new-chat'
    [void](Send-Cdp $Socket $id 'Page.navigate' @{url='https://chatgpt.com/'})
    $id++
    Start-Sleep -Seconds 8

    $Stage='inspect-dom'
    $expression=@'
(() => {
  const pick = el => ({
    tag: el.tagName,
    id: el.id || "",
    role: el.getAttribute("role") || "",
    contenteditable: el.getAttribute("contenteditable") || "",
    testid: el.getAttribute("data-testid") || "",
    placeholder: el.getAttribute("placeholder") || "",
    ariaLabel: el.getAttribute("aria-label") || "",
    classes: typeof el.className === "string" ? el.className.slice(0,300) : "",
    text: (el.innerText || el.value || el.textContent || "").trim().slice(0,300),
    html: el.outerHTML.slice(0,700)
  });
  const selectors = [
    "textarea",
    "[contenteditable]",
    "[role='textbox']",
    ".ProseMirror",
    "[data-testid*='prompt']",
    "[data-testid*='composer']",
    "form"
  ];
  const seen = new Set();
  const items = [];
  for (const selector of selectors) {
    for (const el of document.querySelectorAll(selector)) {
      if (seen.has(el)) continue;
      seen.add(el);
      items.push(pick(el));
      if (items.length >= 40) break;
    }
    if (items.length >= 40) break;
  }
  return {
    href: location.href,
    title: document.title,
    readyState: document.readyState,
    bodyText: (document.body?.innerText || "").trim().slice(0,2500),
    candidates: items
  };
})()
'@
    $dom=Eval $Socket ([ref]$id) $expression
    $json=$dom|ConvertTo-Json -Depth 12 -Compress
    $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

    $Stage='pass'
    Finish 'pass' 0 '' @{
        href=[string]$dom.href
        title=[string]$dom.title
        candidate_count=@($dom.candidates).Count
        dom_json_base64=$b64
    }
}catch{
    Finish 'fail' 31 (([string]$_.Exception.Message)+' | line='+([string]$_.InvocationInfo.ScriptLineNumber))
}finally{
    if($null-ne$Socket){try{$Socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    if($WasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){
        try{Start-Process -FilePath $AppExe|Out-Null}catch{}
    }
}
