param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$original=Join-Path $root 'desktop\v1.56.0\resources\app.asar'
$patched=Join-Path $root 'desktop-ru\v1.56.0\resources\app.asar'
$backup=Join-Path $root 'desktop-ru\v1.56.0\resources\app.asar.original'
$launcher=Join-Path $root 'Goose-RU.cmd'
$r=[ordered]@{status='failed';error='';original_unchanged=$false;patched_present=$false;launcher_correct=$false;node_verify=''}
try{
 if(-not (Test-Path $original -PathType Leaf)){throw 'Original archive missing'}
 if(-not (Test-Path $patched -PathType Leaf)){throw 'Russian archive missing'}
 if(-not (Test-Path $backup -PathType Leaf)){throw 'Original backup missing'}
 $r.original_unchanged=((Get-FileHash $original -Algorithm SHA256).Hash -eq (Get-FileHash $backup -Algorithm SHA256).Hash)
 $lines=Get-Content $launcher -ErrorAction Stop
 $r.launcher_correct=[bool](@($lines|Where-Object{$_ -match 'desktop-ru' -and $_ -match '\-\-dir' -and $_ -match 'workspace'}).Count -eq 1)
 $js=@'
const asar=require('D:/LocalAI/Goose/patch-tools/node_modules/@electron/asar');
const path=require('path');
const a='D:/LocalAI/Goose/desktop-ru/v1.56.0/resources/app.asar';
const main=asar.extractFile(a,'.vite'+path.sep+'build'+path.sep+'main.js').toString('utf8');
const file=asar.listPackage(a).find(x=>x.includes('App-Cz6iiNAZ.js'));
const renderer=asar.extractFile(a,file.replace(/^[\\/]+/,'')).toString('utf8');
const ok=main.includes('GOOSE_RU_NATIVE_MENU_PATCH_V1')&&main.includes('\u0424\u0430\u0439\u043b')&&renderer.includes('\u041f\u0440\u0438\u043a\u0440\u0435\u043f\u0438\u0442\u044c\u0020\u0444\u0430\u0439\u043b');
console.log(JSON.stringify({status:ok?'success':'failed',patched_main:main.includes('GOOSE_RU_NATIVE_MENU_PATCH_V1'),translated_menu:main.includes('\u0424\u0430\u0439\u043b'),translated_attachment:renderer.includes('\u041f\u0440\u0438\u043a\u0440\u0435\u043f\u0438\u0442\u044c\u0020\u0444\u0430\u0439\u043b')}));
'@
 $p=Join-Path $root 'patch-tools\verify-goose-ru.cjs'
 [IO.File]::WriteAllText($p,$js,(New-Object Text.UTF8Encoding($false)))
 $out=Join-Path $root 'logs\verify-goose-ru.json'
 $err=Join-Path $root 'logs\verify-goose-ru.error.log'
 $proc=Start-Process -FilePath 'C:\Program Files\nodejs\node.exe' -ArgumentList @($p) -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
 if(-not $proc.WaitForExit(10000)){try{$proc.Kill()}catch{};throw 'Verification timed out'}
 $data=Get-Content $out -Raw|ConvertFrom-Json
 $r.node_verify=$data.status
 if(-not $r.original_unchanged -or -not $r.launcher_correct -or $data.status -ne 'success'){throw ('Localization check failed: original='+$r.original_unchanged+' launcher='+$r.launcher_correct+' archive='+$r.node_verify+' stdout='+(Get-Content $out -Raw))}
 $r.status='success'
 $r.error='Original archive hash matches backup; Russian menu and tooltip code verified; launcher opens Russian copy in D workspace.'
}catch{$r.error=[string]$_.Exception.Message}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
