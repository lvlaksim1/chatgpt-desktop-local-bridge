param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$r=[ordered]@{status='failed';error='';asar_old='';asar_new='';node_status='';stdout='';stderr=''}
try{
 $js=@'
const asar=require('D:/LocalAI/Goose/patch-tools/node_modules/@electron/asar');
const fs=require('fs');
const dir='D:/LocalAI/Goose/desktop-ru/v1.56.0/resources';
const a=dir+'/app.asar';
const b=dir+'/app.asar.ru-new';
const out={original:[],repacked:[],hasMainOriginal:false,hasMainRepacked:false};
for(const [key,archive] of [['original',a],['repacked',b]]){
 if(!fs.existsSync(archive))continue;
 const files=asar.listPackage(archive);
 out[key]=files.slice(0,22);
 out['hasMain'+key[0].toUpperCase()+key.slice(1)]=files.some(x=>/main\.js/i.test(x));
}
console.log(JSON.stringify(out));
'@
 $p='D:\LocalAI\Goose\patch-tools\inspect-ru-asar.cjs'
 [IO.File]::WriteAllText($p,$js,(New-Object System.Text.UTF8Encoding($false)))
 $stdout='D:\LocalAI\Goose\logs\ru-archive-structure.json'
 $stderr='D:\LocalAI\Goose\logs\ru-archive-structure.err'
 $process=Start-Process -FilePath 'C:\Program Files\nodejs\node.exe' -ArgumentList @($p) -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
 if(-not $process.WaitForExit(10000)){try{$process.Kill()}catch{};throw 'Node inspection timed out'}
 $data=Get-Content -LiteralPath $stdout -Raw|ConvertFrom-Json
 $r.asar_old=@($data.original) -join ','
 $r.asar_new=@($data.repacked) -join ','
 $r.status='success'
 $r.error='old='+$r.asar_old+' | new='+$r.asar_new
}catch{$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 675){$r.error=$r.error.Substring(0,675)}
$r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
