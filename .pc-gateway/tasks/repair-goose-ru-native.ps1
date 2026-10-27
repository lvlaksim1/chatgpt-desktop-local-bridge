param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$exe=Join-Path $root 'desktop-ru\v1.56.0\Goose.exe'
$originalExe=Join-Path $root 'desktop\v1.56.0\Goose.exe'
$asar=Join-Path $root 'desktop-ru\v1.56.0\resources\app.asar'
$originalAsar=Join-Path $root 'desktop\v1.56.0\resources\app.asar'
$asarBackup=Join-Path $root 'desktop-ru\v1.56.0\resources\app.asar.original'
$exeBackup=$exe+'.before-ru-integrity'
$cmd=Join-Path $root 'Goose-RU.cmd'
$vbs=Join-Path $root 'Goose-RU.vbs'
$logs=Join-Path $root 'logs'
$r=[ordered]@{status='failed';stage='preflight';error='';integrity_fixed=$false;console_hidden=$false;shortcut_updated=$false;original_unchanged=$false;integrity_hash='';runtime_smoke_test='not_run'}
try {
 New-Item -ItemType Directory -Path $logs,(Join-Path $root 'workspace') -Force|Out-Null
 foreach($p in @($exe,$originalExe,$asar,$originalAsar,$asarBackup,$cmd)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing: $p"}}
 $originalHash=(Get-FileHash -LiteralPath $originalExe -Algorithm SHA256).Hash
 if((Get-FileHash -LiteralPath $originalAsar -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $asarBackup -Algorithm SHA256).Hash){throw 'Original ASAR and localized backup differ'}
 $node=Get-Command node.exe -ErrorAction Stop
 $js=@'
const asar=require('D:/LocalAI/Goose/patch-tools/node_modules/@electron/asar');
const crypto=require('node:crypto');
const p='D:/LocalAI/Goose/desktop-ru/v1.56.0/resources/app.asar';
if(!asar.extractFile(p,require('node:path').join('.vite','build','main.js')).toString('utf8').includes('GOOSE_RU_NATIVE_MENU_PATCH_V1'))throw Error('Russian patch missing');
console.log(crypto.createHash('sha256').update(asar.getRawHeader(p).headerString).digest('hex'));
'@
 $jsPath=Join-Path $root 'patch-tools\goose-ru-header-hash.cjs'
 [IO.File]::WriteAllText($jsPath,$js,(New-Object Text.UTF8Encoding($false)))
 $hashOut=Join-Path $logs 'goose-ru-header-hash.out'
 $hashErr=Join-Path $logs 'goose-ru-header-hash.err'
 $np=Start-Process -FilePath $node.Source -ArgumentList @($jsPath) -PassThru -NoNewWindow -RedirectStandardOutput $hashOut -RedirectStandardError $hashErr
 if(-not $np.WaitForExit(25000)){try{$np.Kill()}catch{};throw 'ASAR header hash timed out'}
 $np.Refresh()
 $hash=([string](Get-Content -LiteralPath $hashOut -Raw -ErrorAction SilentlyContinue)).Trim()
 if($hash -notmatch '^[0-9a-f]{64}
 $r.integrity_hash=$hash
 $r.stage='win32-resource'
 $cs=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GooseRuIntegrityWin32 {
 public delegate bool LangCallback(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr context);
 [DllImport("kernel32.dll",EntryPoint="LoadLibraryExW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern bool FreeLibrary(IntPtr module);
 [DllImport("kernel32.dll",EntryPoint="EnumResourceLanguagesW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool EnumResourceLanguages(IntPtr module,string type,string name,LangCallback fn,IntPtr context);
 [DllImport("kernel32.dll",EntryPoint="FindResourceExW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr FindResourceEx(IntPtr module,string type,string name,ushort lang);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern IntPtr LoadResource(IntPtr module,IntPtr resource);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern IntPtr LockResource(IntPtr resource);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern uint SizeofResource(IntPtr module,IntPtr resource);
 [DllImport("kernel32.dll",EntryPoint="BeginUpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr BeginUpdateResource(string path,bool deleteExisting);
 [DllImport("kernel32.dll",EntryPoint="UpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool UpdateResource(IntPtr update,string type,string name,ushort language,byte[] bytes,uint length);
 [DllImport("kernel32.dll",EntryPoint="EndUpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool EndUpdateResource(IntPtr update,bool discard);
 public static int Language(string path){
  IntPtr module=LoadLibraryEx(path,IntPtr.Zero,2);
  if(module==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadLibraryEx");
  try {
   int found=-1;
   LangCallback callback=delegate(IntPtr m,IntPtr t,IntPtr n,ushort language,IntPtr context){found=language;return false;};
   EnumResourceLanguages(module,"INTEGRITY","ELECTRONASAR",callback,IntPtr.Zero);
   if(found<0)throw new Exception("INTEGRITY/ELECTRONASAR PE resource not found");
   return found;
  }finally{FreeLibrary(module);}
 }
 public static byte[] Read(string path, int language){
  IntPtr module=LoadLibraryEx(path,IntPtr.Zero,2);
  if(module==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadLibraryEx");
  try {
   IntPtr resource=FindResourceEx(module,"INTEGRITY","ELECTRONASAR",(ushort)language);
   if(resource==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"FindResourceEx");
   uint size=SizeofResource(module,resource);
   IntPtr handle=LoadResource(module,resource);
   if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadResource");
   IntPtr ptr=LockResource(handle);
   if(ptr==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LockResource");
   byte[] bytes=new byte[size];
   Marshal.Copy(ptr,bytes,0,(int)size);
   return bytes;
  }finally{FreeLibrary(module);}
 }
 public static void Update(string path,int language,byte[] bytes){
  IntPtr h=BeginUpdateResource(path,false);
  if(h==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"BeginUpdateResource");
  bool ended=false;
  try {
   if(!UpdateResource(h,"INTEGRITY","ELECTRONASAR",(ushort)language,bytes,(uint)bytes.Length))throw new Win32Exception(Marshal.GetLastWin32Error(),"UpdateResource");
   if(!EndUpdateResource(h,false))throw new Win32Exception(Marshal.GetLastWin32Error(),"EndUpdateResource");
   ended=true;
  } finally {if(!ended)EndUpdateResource(h,true);}
 }
}
'@
 Add-Type -TypeDefinition $cs -ErrorAction Stop
 $lang=[GooseRuIntegrityWin32]::Language($exe)
 $entries=[Text.Encoding]::UTF8.GetString([GooseRuIntegrityWin32]::Read($exe,$lang))|ConvertFrom-Json
 $matches=@($entries|Where-Object{[string]$_.file -and $_.file.Replace('/','\').ToLowerInvariant() -eq 'resources\app.asar'})
 if($matches.Count -ne 1){throw "Expected one ASAR integrity record; found $($matches.Count)"}
 if(([string]$matches[0].alg).ToLowerInvariant() -ne 'sha256'){throw 'Unsupported ASAR integrity algorithm'}
 if(([string]$matches[0].value).ToLowerInvariant() -ne $hash){
  if(Test-Path -LiteralPath $exeBackup -PathType Leaf){throw 'Previous EXE backup exists but integrity still mismatches: aborting'}
  $r.stage='patch-copy'
  Copy-Item -LiteralPath $exe -Destination $exeBackup
  $matches[0].value=$hash
  $json=ConvertTo-Json -InputObject @($entries) -Compress -Depth 6
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $pending=$exe+'.ru-integrity-pending'
  $swap=$exe+'.ru-integrity-swap'
  if((Test-Path $pending) -or (Test-Path $swap)){throw 'Temporary executable already exists; aborting'}
  Copy-Item -LiteralPath $exe -Destination $pending
  [GooseRuIntegrityWin32]::Update($pending,$lang,$bytes)
  $verified=[Text.Encoding]::UTF8.GetString([GooseRuIntegrityWin32]::Read($pending,$lang))|ConvertFrom-Json
  $matchesVerified=@($verified|Where-Object{$_.file.Replace('/','\').ToLowerInvariant() -eq 'resources\app.asar'})
  if($matchesVerified.Count -ne 1 -or ([string]$matchesVerified[0].value).ToLowerInvariant() -ne $hash){throw 'Updated resource verification failed'}
  Move-Item -LiteralPath $exe -Destination $swap
  try {Move-Item -LiteralPath $pending -Destination $exe}
  catch {Move-Item -LiteralPath $swap -Destination $exe;throw}
  Remove-Item -LiteralPath $swap -Force
 }
 $r.integrity_fixed=$true
 $r.original_unchanged=((Get-FileHash -LiteralPath $originalExe -Algorithm SHA256).Hash -eq $originalHash)
 if(-not $r.original_unchanged){throw 'Original Goose.exe was modified unexpectedly'}
 $r.stage='launcher'
 $lines=@(Get-Content -LiteralPath $cmd)
 $count=0
 for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -match '^start\s'){
   $lines[$i]='start "" /D "D:\LocalAI\Goose\workspace" "D:\LocalAI\Goose\desktop-ru\v1.56.0\Goose.exe" --dir "D:\LocalAI\Goose\workspace"'
   $count++
  }
 }
 if($count -ne 1){throw "Expected one start command in launcher, found $count"}
 $saved=Join-Path $root 'backups\Goose-RU.before-hidden-launch.cmd'
 New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force|Out-Null
 if(-not(Test-Path $saved -PathType Leaf)){Copy-Item -LiteralPath $cmd -Destination $saved}
 [IO.File]::WriteAllLines($cmd,$lines,[Text.Encoding]::ASCII)
 $vbsCode=@'
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "D:\LocalAI\Goose\Goose-RU.cmd" & Chr(34), 0, False
'@
 [IO.File]::WriteAllText($vbs,$vbsCode,(New-Object Text.UTF8Encoding($false)))
 $r.console_hidden=Test-Path -LiteralPath $vbs -PathType Leaf
 $r.stage='shortcut'
 $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
 if([string]::IsNullOrWhiteSpace($desktop)){throw 'Desktop path not accessible'}
 $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2UgLSDQoNGD0YHRgdC60LjQuS5sbms='))
 $shortcut=Join-Path $desktop $name
 $shell=New-Object -ComObject WScript.Shell
 $lnk=$shell.CreateShortcut($shortcut)
 $lnk.TargetPath=Join-Path $env:SystemRoot 'System32\wscript.exe'
 $lnk.Arguments='"D:\LocalAI\Goose\Goose-RU.vbs"'
 $lnk.WorkingDirectory=Join-Path $root 'workspace'
 $lnk.IconLocation=$exe+',0'
 $lnk.Save()
 $r.shortcut_updated=$true
 $r.stage='done'
 $r.status='success'
 $r.error='Russian ASAR hash and embedded EXE integrity resource match; desktop launcher is hidden. Visual launch is pending.'
}catch{$r.error=([string]$_.Exception.Message -replace '[\r\n]+',' ')}
if($r.error.Length -gt 675){$r.error=$r.error.Substring(0,675)}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
){throw ('ASAR header hash invalid; exit='+[string]$np.ExitCode+'; stderr='+(Get-Content -LiteralPath $hashErr -Raw -ErrorAction SilentlyContinue))}
 # The 64-character hash is the direct verified output of our hash-only script.
 # Some GitHub runner PowerShell processes report an unreliable child exit code here.

 $r.integrity_hash=$hash
 $r.stage='win32-resource'
 $cs=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GooseRuIntegrityWin32 {
 public delegate bool LangCallback(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr context);
 [DllImport("kernel32.dll",EntryPoint="LoadLibraryExW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern bool FreeLibrary(IntPtr module);
 [DllImport("kernel32.dll",EntryPoint="EnumResourceLanguagesW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool EnumResourceLanguages(IntPtr module,string type,string name,LangCallback fn,IntPtr context);
 [DllImport("kernel32.dll",EntryPoint="FindResourceExW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr FindResourceEx(IntPtr module,string type,string name,ushort lang);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern IntPtr LoadResource(IntPtr module,IntPtr resource);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern IntPtr LockResource(IntPtr resource);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern uint SizeofResource(IntPtr module,IntPtr resource);
 [DllImport("kernel32.dll",EntryPoint="BeginUpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr BeginUpdateResource(string path,bool deleteExisting);
 [DllImport("kernel32.dll",EntryPoint="UpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool UpdateResource(IntPtr update,string type,string name,ushort language,byte[] bytes,uint length);
 [DllImport("kernel32.dll",EntryPoint="EndUpdateResourceW",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern bool EndUpdateResource(IntPtr update,bool discard);
 public static int Language(string path){
  IntPtr module=LoadLibraryEx(path,IntPtr.Zero,2);
  if(module==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadLibraryEx");
  try {
   int found=-1;
   LangCallback callback=delegate(IntPtr m,IntPtr t,IntPtr n,ushort language,IntPtr context){found=language;return false;};
   EnumResourceLanguages(module,"INTEGRITY","ELECTRONASAR",callback,IntPtr.Zero);
   if(found<0)throw new Exception("INTEGRITY/ELECTRONASAR PE resource not found");
   return found;
  }finally{FreeLibrary(module);}
 }
 public static byte[] Read(string path, int language){
  IntPtr module=LoadLibraryEx(path,IntPtr.Zero,2);
  if(module==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadLibraryEx");
  try {
   IntPtr resource=FindResourceEx(module,"INTEGRITY","ELECTRONASAR",(ushort)language);
   if(resource==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"FindResourceEx");
   uint size=SizeofResource(module,resource);
   IntPtr handle=LoadResource(module,resource);
   if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LoadResource");
   IntPtr ptr=LockResource(handle);
   if(ptr==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"LockResource");
   byte[] bytes=new byte[size];
   Marshal.Copy(ptr,bytes,0,(int)size);
   return bytes;
  }finally{FreeLibrary(module);}
 }
 public static void Update(string path,int language,byte[] bytes){
  IntPtr h=BeginUpdateResource(path,false);
  if(h==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"BeginUpdateResource");
  bool ended=false;
  try {
   if(!UpdateResource(h,"INTEGRITY","ELECTRONASAR",(ushort)language,bytes,(uint)bytes.Length))throw new Win32Exception(Marshal.GetLastWin32Error(),"UpdateResource");
   if(!EndUpdateResource(h,false))throw new Win32Exception(Marshal.GetLastWin32Error(),"EndUpdateResource");
   ended=true;
  } finally {if(!ended)EndUpdateResource(h,true);}
 }
}
'@
 Add-Type -TypeDefinition $cs -ErrorAction Stop
 $lang=[GooseRuIntegrityWin32]::Language($exe)
 $entries=[Text.Encoding]::UTF8.GetString([GooseRuIntegrityWin32]::Read($exe,$lang))|ConvertFrom-Json
 $matches=@($entries|Where-Object{[string]$_.file -and $_.file.Replace('/','\').ToLowerInvariant() -eq 'resources\app.asar'})
 if($matches.Count -ne 1){throw "Expected one ASAR integrity record; found $($matches.Count)"}
 if(([string]$matches[0].alg).ToLowerInvariant() -ne 'sha256'){throw 'Unsupported ASAR integrity algorithm'}
 if(([string]$matches[0].value).ToLowerInvariant() -ne $hash){
  if(Test-Path -LiteralPath $exeBackup -PathType Leaf){throw 'Previous EXE backup exists but integrity still mismatches: aborting'}
  $r.stage='patch-copy'
  Copy-Item -LiteralPath $exe -Destination $exeBackup
  $matches[0].value=$hash
  $json=ConvertTo-Json -InputObject @($entries) -Compress -Depth 6
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $pending=$exe+'.ru-integrity-pending'
  $swap=$exe+'.ru-integrity-swap'
  if((Test-Path $pending) -or (Test-Path $swap)){throw 'Temporary executable already exists; aborting'}
  Copy-Item -LiteralPath $exe -Destination $pending
  [GooseRuIntegrityWin32]::Update($pending,$lang,$bytes)
  $verified=[Text.Encoding]::UTF8.GetString([GooseRuIntegrityWin32]::Read($pending,$lang))|ConvertFrom-Json
  $matchesVerified=@($verified|Where-Object{$_.file.Replace('/','\').ToLowerInvariant() -eq 'resources\app.asar'})
  if($matchesVerified.Count -ne 1 -or ([string]$matchesVerified[0].value).ToLowerInvariant() -ne $hash){throw 'Updated resource verification failed'}
  Move-Item -LiteralPath $exe -Destination $swap
  try {Move-Item -LiteralPath $pending -Destination $exe}
  catch {Move-Item -LiteralPath $swap -Destination $exe;throw}
  Remove-Item -LiteralPath $swap -Force
 }
 $r.integrity_fixed=$true
 $r.original_unchanged=((Get-FileHash -LiteralPath $originalExe -Algorithm SHA256).Hash -eq $originalHash)
 if(-not $r.original_unchanged){throw 'Original Goose.exe was modified unexpectedly'}
 $r.stage='launcher'
 $lines=@(Get-Content -LiteralPath $cmd)
 $count=0
 for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -match '^start\s'){
   $lines[$i]='start "" /D "D:\LocalAI\Goose\workspace" "D:\LocalAI\Goose\desktop-ru\v1.56.0\Goose.exe" --dir "D:\LocalAI\Goose\workspace"'
   $count++
  }
 }
 if($count -ne 1){throw "Expected one start command in launcher, found $count"}
 $saved=Join-Path $root 'backups\Goose-RU.before-hidden-launch.cmd'
 New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force|Out-Null
 if(-not(Test-Path $saved -PathType Leaf)){Copy-Item -LiteralPath $cmd -Destination $saved}
 [IO.File]::WriteAllLines($cmd,$lines,[Text.Encoding]::ASCII)
 $vbsCode=@'
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "D:\LocalAI\Goose\Goose-RU.cmd" & Chr(34), 0, False
'@
 [IO.File]::WriteAllText($vbs,$vbsCode,(New-Object Text.UTF8Encoding($false)))
 $r.console_hidden=Test-Path -LiteralPath $vbs -PathType Leaf
 $r.stage='shortcut'
 $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
 if([string]::IsNullOrWhiteSpace($desktop)){throw 'Desktop path not accessible'}
 $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2UgLSDQoNGD0YHRgdC60LjQuS5sbms='))
 $shortcut=Join-Path $desktop $name
 $shell=New-Object -ComObject WScript.Shell
 $lnk=$shell.CreateShortcut($shortcut)
 $lnk.TargetPath=Join-Path $env:SystemRoot 'System32\wscript.exe'
 $lnk.Arguments='"D:\LocalAI\Goose\Goose-RU.vbs"'
 $lnk.WorkingDirectory=Join-Path $root 'workspace'
 $lnk.IconLocation=$exe+',0'
 $lnk.Save()
 $r.shortcut_updated=$true
 $r.stage='done'
 $r.status='success'
 $r.error='Russian ASAR hash and embedded EXE integrity resource match; desktop launcher is hidden. Visual launch is pending.'
}catch{$r.error=([string]$_.Exception.Message -replace '[\r\n]+',' ')}
if($r.error.Length -gt 675){$r.error=$r.error.Substring(0,675)}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
