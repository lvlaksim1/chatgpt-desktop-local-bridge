[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
$Root=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$Exe=Join-Path $Root 'ChatGptDesktopLocalBridge.exe'
$Old=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')
$script:Socket=$null; $script:Id=1
function Finish([string]$s,[int]$c,[string]$e){
  @{status=$s;exit_code=$c;error=$e}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit $c
}
function Stop-All{
  Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}
function Wait-App{
  $end=[DateTime]::UtcNow.AddSeconds(45)
  while([DateTime]::UtcNow -lt $end){
    $p=@(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
    if($p.Count){return $true}
    Start-Sleep -Milliseconds 500
  }
  return $false
}
function Wait-Ws([int]$Port){
  $end=[DateTime]::UtcNow.AddSeconds(60)
  while([DateTime]::UtcNow -lt $end){
    try{
      $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
      $t=@($items|Where-Object{$_.type -eq 'page' -and ([string]$_.url) -like 'https://chatgpt.com/*' -and -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)}|Select-Object -First 1)
      if($t.Count){return [string]$t[0].webSocketDebuggerUrl}
    }catch{}
    Start-Sleep -Seconds 5
  }
  return ''
}
function Cdp([string]$Method,[hashtable]$Params){
  $id=$script:Id; $script:Id++
  $json=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Depth 20 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $seg=New-Object ArraySegment[byte] -ArgumentList (, $bytes)
  $cts=New-Object Threading.CancellationTokenSource
  $cts.CancelAfter(180000)
  try{
    [void]($script:Socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
    while($true){
      $ms=New-Object IO.MemoryStream
      try{
        do{
          $buf=New-Object byte[] 65536
          $bseg=New-Object ArraySegment[byte] -ArgumentList (, $buf)
          $rx=$script:Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
          if($rx.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'cdp_closed'}
          $ms.Write($buf,0,$rx.Count)
        }while(-not $rx.EndOfMessage)
        $m=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
        if($null -ne $m.PSObject.Properties['id'] -and [int]$m.id -eq $id){return $m}
      }finally{$ms.Dispose()}
    }
  }finally{$cts.Dispose()}
}
try{
  if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw 'installed_app_missing'}
  Stop-All
  $port=Get-Random -Minimum 9400 -Maximum 9999
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
  Start-Process -FilePath $Exe|Out-Null
  if(-not(Wait-App)){throw 'app_window_missing'}
  $ws=Wait-Ws $port
  if([string]::IsNullOrWhiteSpace($ws)){throw 'cdp_target_missing'}
  $script:Socket=New-Object Net.WebSockets.ClientWebSocket
  $script:Socket.Options.Proxy=$null
  $script:Socket.ConnectAsync([Uri]$ws,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Start-Sleep -Seconds 15
  $js=@'
(async()=>{
 const delay=ms=>new Promise(r=>setTimeout(r,ms));
 const r1=await fetch('/backend-api/automations?filter=paused',{credentials:'include',headers:{accept:'application/json'}});
 const t1=await r1.text();
 if(!r1.ok)return{stage:'list',status:r1.status,text:t1.slice(0,400)};
 const j=JSON.parse(t1||'{}'),items=Array.isArray(j.items)?j.items:[];
 const item=items.find(x=>x&&typeof x.id==='string')||null;
 if(!item)return{stage:'list',status:r1.status,no_item:true,list_keys:Object.keys(j).sort()};
 await delay(5000);
 const r2=await fetch('/backend-api/automation/'+encodeURIComponent(item.id),{credentials:'include',headers:{accept:'application/json'}});
 const t2=await r2.text();
 if(!r2.ok)return{stage:'detail',status:r2.status,text:t2.slice(0,400)};
 const d=JSON.parse(t2||'{}');
 const rel=o=>Object.keys(o||{}).filter(k=>/file|attach|upload|asset|content|meta|resource/i.test(k)).sort();
 return{
   stage:'ok',
   list_keys:Object.keys(j).sort(),
   item_keys:Object.keys(item).sort(),
   detail_keys:Object.keys(d).sort(),
   item_relevant:rel(item),
   detail_relevant:rel(d)
 };
})()
'@
  $r=Cdp 'Runtime.evaluate' @{expression=$js;returnByValue=$true;awaitPromise=$true}
  if($null -ne $r.PSObject.Properties['error']){throw 'cdp_error'}
  if($null -ne $r.result.PSObject.Properties['exceptionDetails']){throw 'js_exception'}
  $v=$r.result.result.value|ConvertTo-Json -Depth 10 -Compress
  $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v))
  Finish 'evidence' 7 ('EVIDENCE_B64='+$b64)
}catch{Finish 'fail' 40 $_.Exception.Message}
finally{
  if($null -ne $script:Socket){try{$script:Socket.Dispose()}catch{}}
  try{Stop-All}catch{}
  [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$Old,'Process')
}
