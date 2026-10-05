[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe=Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath=Join-Path $InstallRoot 'release-info.json'
$ProcessName='ChatGptDesktopLocalBridge'
$ExpectedTag='private-transport-v5-95dd011'
$socket=$null
$oldBrowserArgs=[Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','Process')

function Write-ProjectResult {
 param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
 $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;expected_release=$ExpectedTag}
 foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
 $dir=Split-Path -Parent $GatewayResultPath
 if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
 $payload|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
 exit $ExitCode
}
function Stop-BridgeApp {
 foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{if($p.MainWindowHandle-ne0){[void]$p.CloseMainWindow()}}catch{}}
 Start-Sleep -Seconds 2
 foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){try{Stop-Process -Id $p.Id -Force}catch{}}
 Start-Sleep -Seconds 1
}
function Stop-BridgeWebViewProcesses {
 $needle='ChatGptDesktopLocalBridge\WebView2'
 foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine-like('*'+$needle+'*')})){try{Stop-Process -Id ([int]$p.ProcessId) -Force}catch{}}
 Start-Sleep -Seconds 1
}
function Wait-BridgeProcess {
 param([int]$TimeoutSeconds=45)
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
 while([DateTime]::UtcNow-lt$deadline){
  $items=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle-ne0}|Select-Object -First 1)
  if($items.Count-gt0){return $items[0]}
  Start-Sleep -Milliseconds 500
 }
 return $null
}
function Wait-ForCdpTarget {
 param([int]$Port,[int]$TimeoutSeconds=60)
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
 while([DateTime]::UtcNow-lt$deadline){
  try{
   $targets=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Port+'/json') -UseBasicParsing -TimeoutSec 2)
   $target=@($targets|Where-Object{$_.type-eq'page'-and$_.url-like'https://chatgpt.com/*'-and-not[string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)}|Select-Object -First 1)
   if($target.Count-gt0){return $target[0]}
  }catch{}
  Start-Sleep -Milliseconds 500
 }
 return $null
}
function Send-CdpCommand {
 param([System.Net.WebSockets.ClientWebSocket]$Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{},[int]$TimeoutMs=120000)
 $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 40 -Compress
 $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
 $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
 $cts=New-Object System.Threading.CancellationTokenSource
 $cts.CancelAfter($TimeoutMs)
 try{
  [void]($Socket.SendAsync($seg,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
  while($true){
   $ms=New-Object IO.MemoryStream
   try{
    do{
     $buf=New-Object byte[] 65536
     $bseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
     $recv=$Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
     if($recv.MessageType-eq[System.Net.WebSockets.WebSocketMessageType]::Close){throw'CDP websocket closed.'}
     $ms.Write($buf,0,$recv.Count)
    }while(-not$recv.EndOfMessage)
    $msg=([Text.Encoding]::UTF8.GetString($ms.ToArray())|ConvertFrom-Json)
    if($null-ne$msg.PSObject.Properties['id']-and[int]$msg.id-eq$Id){return $msg}
   }finally{$ms.Dispose()}
  }
 }finally{$cts.Dispose()}
}
function Invoke-CdpEval {
 param([System.Net.WebSockets.ClientWebSocket]$Socket,[ref]$Id,[string]$Expression,[string]$Stage,[int]$TimeoutMs=120000)
 $r=Send-CdpCommand -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{expression=$Expression;returnByValue=$true;awaitPromise=$true} -TimeoutMs $TimeoutMs
 $Id.Value++
 if($null-ne$r.PSObject.Properties['error']){throw($Stage+': CDP error')}
 $inner=$r.result.result
 if($null-ne$inner.PSObject.Properties['exceptionDetails']){throw($Stage+': JS exception')}
 if($null-eq$inner.PSObject.Properties['value']){throw($Stage+': missing value')}
 return $inner.value
}

$port=Get-Random -Minimum 9400 -Maximum 9999
$cdpId=1
$installedTag=$null
try{
 if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw'Installed app missing'}
 $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
 $installedTag=[string]$release.tag
 if($installedTag-ne$ExpectedTag){throw"Installed release '$installedTag' is not '$ExpectedTag'"}

 Stop-BridgeApp
 Stop-BridgeWebViewProcesses
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
 Start-Process -FilePath $AppExe|Out-Null
 if($null-eq(Wait-BridgeProcess 45)){throw'App main window missing'}
 $target=Wait-ForCdpTarget -Port $port -TimeoutSeconds 60
 if($null-eq$target){throw'CDP target missing'}
 $socket=New-Object System.Net.WebSockets.ClientWebSocket
 $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
 [void](Send-CdpCommand -Socket $socket -Id $cdpId -Method 'Page.navigate' -Params @{url='https://chatgpt.com/'})
 $cdpId++
 Start-Sleep -Seconds 3

 $script=@"
(async()=>{
 const delay=ms=>new Promise(r=>setTimeout(r,ms));
 async function auth(){
  const r=await fetch('/api/auth/session',{credentials:'include',cache:'no-store',headers:{accept:'application/json'}});
  if(!r.ok)throw new Error('auth_'+r.status);
  const s=await r.json();if(typeof s?.accessToken!=='string')throw new Error('no_token');
  return {token:s.accessToken,accountId:typeof s?.account?.id==='string'?s.account.id:''};
 }
 const a=await auth();
 const headers={accept:'application/json, text/plain, */*',authorization:'Bearer '+a.token};
 if(a.accountId)headers['chatgpt-account-id']=a.accountId;
 async function jsonApi(method,path,body){
  const h={...headers},init={method,credentials:'include',redirect:'error',cache:'no-store',headers:h};
  if(body!==undefined){h['content-type']='application/json';init.body=JSON.stringify(body)}
  const r=await fetch(path,init),raw=await r.text();let json=null;try{json=raw?JSON.parse(raw):null}catch{}
  return {ok:r.ok,status:r.status,json,raw};
 }
 async function textApi(method,path){
  const r=await fetch(path,{method,credentials:'include',redirect:'error',cache:'no-store',headers:{...headers}});
  return {ok:r.ok,status:r.status,raw:await r.text()};
 }
 function parseNdjson(raw){
  const out=[];for(const line of String(raw||'').split(/\r?\n/)){if(!line.trim())continue;try{out.push(JSON.parse(line))}catch{}}
  return out;
 }
 async function listLibrary(){
  const r=await jsonApi('POST','/backend-api/files/library',{limit:100});
  if(!r.ok||!Array.isArray(r.json?.items))throw new Error('library_'+r.status);return r.json.items;
 }
 async function download(item){
  const r=await fetch('/api/library/files/'+encodeURIComponent(item.id)+'/download',{credentials:'include',cache:'no-store'});
  return {ok:r.ok,status:r.status,text:await r.text()};
 }
 async function del(item){
  const u=new URL('/backend-api/files/library/files/'+encodeURIComponent(item.id)+'/delete_stream',location.origin);
  u.searchParams.set('file_id',item.file_id);
  if(item.directory_id!=null)u.searchParams.set('parent_directory_id',String(item.directory_id));
  u.searchParams.set('file_name',item.file_name||'');
  u.searchParams.set('soft_delete','true');
  const r=await textApi('POST',u.pathname+u.search),events=parseNdjson(r.raw);
  return {status:r.status,completed:events.some(x=>x?.event==='file.deletion.completed')};
 }

 const filters=['scheduled','paused','finished'];
 const tasks=[];
 for(const f of filters){
  const r=await jsonApi('GET','/backend-api/automations?filter='+f);
  if(r.ok&&Array.isArray(r.json?.items))tasks.push(...r.json.items);
 }
 const workerMap=new Map();
 for(const t of tasks){
  if(!t||typeof t.id!=='string'||workerMap.has(t.id))continue;
  const p=String(t.prompt||'');
  if(p.startsWith('PRIVATE TRANSPORT E2E WORKER V2.')||p.includes('FULL-FILE-DATAPLANE-V2-DESKTOP')){
   workerMap.set(t.id,t);
  }
 }
 const workers=[];
 let requestName=null,resultName=null;
 for(const t of workerMap.values()){
  const p=String(t.prompt||'');
  const req=/Find the Library file named exactly:\s*([^\n\r]+)/.exec(p);
  const res=/Create a JSON file named exactly:\s*([^\n\r]+)/.exec(p);
  if(req)requestName=req[1].trim();
  if(res)resultName=res[1].trim();
  let disabled=false;
  if(t.is_enabled===true){
   const w=await jsonApi('POST','/backend-api/automations/set_status',{jawbone_id:t.id,is_enabled:false});
   disabled=w.status===201||w.ok;
  }else disabled=true;
  const latest=await jsonApi('GET','/backend-api/automation/'+encodeURIComponent(t.id)+'/latest_backing_run?include_snapshot=true');
  workers.push({
   id:t.id,title:String(t.title||'').slice(0,120),was_enabled:t.is_enabled===true,disabled,
   last_run_present:!!t.last_run_time,latest_run_http:latest.status,
   request_name_present:!!req,result_name_present:!!res
  });
 }

 const items=await listLibrary();
 const candidates=items.filter(x=>x&&x.trashed_at==null&&typeof x.file_name==='string'&&(
  x.file_name.startsWith('bridge-e2e-')||
  (requestName&&x.file_name===requestName)||
  (resultName&&x.file_name===resultName)
 ));
 let request=null,result=null;
 for(const x of candidates){
  if(x.file_name.endsWith('-request.json')||x.file_name===requestName)request=x;
  if(x.file_name.endsWith('-result.json')||x.file_name===resultName)result=x;
 }
 let requestParsed=null,resultParsed=null,resultVerified=false;
 if(request){const d=await download(request);if(d.ok){try{requestParsed=JSON.parse(d.text)}catch{}}}
 if(result){const d=await download(result);if(d.ok){try{resultParsed=JSON.parse(d.text)}catch{}}}
 if(requestParsed&&resultParsed){
  resultVerified=
   resultParsed.protocol==='FULL-FILE-DATAPLANE-V2-DESKTOP'&&
   resultParsed.message_id===requestParsed.message_id&&
   resultParsed.payload===requestParsed.payload&&
   resultParsed.ack==='WORKER-ACK-'+requestParsed.payload;
 }
 const cleanup=[];
 for(const x of candidates){
  try{const d=await del(x);cleanup.push({name:x.file_name,status:d.status,completed:d.completed})}
  catch{cleanup.push({name:x.file_name,status:0,completed:false})}
 }

 return {
  worker_count:workers.length,workers,
  request_found:!!request,result_found:!!result,result_verified:resultVerified,
  request_message_id_present:!!requestParsed?.message_id,
  cleanup_count:cleanup.length,
  cleanup_all:cleanup.every(x=>x.completed),
  cleanup
 };
})()
"@
 $result=Invoke-CdpEval -Socket $socket -Id ([ref]$cdpId) -Expression $script -Stage 'e2e-reconcile' -TimeoutMs 120000
 $safe=[ordered]@{
  worker_count=[int]$result.worker_count
  workers=@($result.workers)
  request_found=[bool]$result.request_found
  result_found=[bool]$result.result_found
  result_verified=[bool]$result.result_verified
  request_message_id_present=[bool]$result.request_message_id_present
  cleanup_count=[int]$result.cleanup_count
  cleanup_all=[bool]$result.cleanup_all
 }
 Write-Host ('E2E_RECONCILE_RESULT='+($safe|ConvertTo-Json -Depth 12 -Compress))
 Write-ProjectResult -Status 'pass' -ExitCode 0 -Extra @{installed_tag=$installedTag;evidence=$safe}
}
catch{
 Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{installed_tag=$installedTag}
}
finally{
 if($null-ne$socket){try{$socket.Dispose()}catch{}}
 try{Stop-BridgeApp}catch{}
 try{Stop-BridgeWebViewProcesses}catch{}
 [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$oldBrowserArgs,'Process')
}
