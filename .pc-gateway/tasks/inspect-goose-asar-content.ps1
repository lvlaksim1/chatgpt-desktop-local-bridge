param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$toolsRoot=Join-Path $root 'patch-tools'
$asar=Join-Path $root 'desktop\v1.56.0\resources\app.asar'
$r=[ordered]@{status='failed';error='';npm_status='';node_version='';files=@();interesting=@();english_attach_files=@();main_snippets=@()}
try{
 New-Item -ItemType Directory -Path $toolsRoot -Force|Out-Null
 if(-not (Test-Path -LiteralPath $asar -PathType Leaf)){throw 'Desktop app.asar missing'}
 $node=Get-Command node.exe -ErrorAction Stop
 $npm=Get-Command npm.cmd -ErrorAction Stop
 $r.node_version=[string](& $node.Source --version)
 $target=Join-Path $toolsRoot 'node_modules\@electron\asar'
 if(-not (Test-Path -LiteralPath $target)){
  $npmout=Join-Path $toolsRoot 'npm-asar-out.log'
  $npmerr=Join-Path $toolsRoot 'npm-asar-err.log'
  $args=@('install','--prefix',$toolsRoot,'--no-audit','--no-fund','@electron/asar@3.4.0')
  $proc=Start-Process -FilePath $npm.Source -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput $npmout -RedirectStandardError $npmerr
  if(-not $proc.WaitForExit(85000)){try{$proc.Kill()}catch{};throw 'npm installation of ASAR inspection tools exceeded 85 seconds'}
  $r.npm_status=[string]$proc.ExitCode
  if($proc.ExitCode -ne 0){$tail=(Get-Content $npmerr -Tail 7|Out-String).Trim();throw ('npm asar install failed: '+$tail)}
 }
 $js=@'
const asar=require('./node_modules/@electron/asar');
const path=require('node:path');
const archive=path.resolve('D:/LocalAI/Goose/desktop/v1.56.0/resources/app.asar');
const files=asar.listPackage(archive).map(x=>x.replace(/^\\|^\//,''));
const jsFiles=files.filter(x=>/\.(js|cjs)$/i.test(x));
const result={file_count:files.length,js_count:jsFiles.length,files:files.filter(x=>/(main|renderer|preload|index\.js)/i.test(x)).slice(0,35), main:[],attach:[]};
for(const file of jsFiles){
 let content;
 try{content=asar.extractFile(archive,file).toString('utf8')}catch{continue}
 if(/MENU_TRANSLATIONS_ZH_CN|Toggle Navigation|function menuT/.test(content)){
  const i=content.indexOf('MENU_TRANSLATIONS_ZH_CN');
  result.main.push({path:file,bytes:content.length,index:i,snippet:content.slice(Math.max(0,i-120),i+400)});
 }
 if(content.includes('Attach file')){
  const i=content.indexOf('Attach file');
  result.attach.push({path:file,bytes:content.length,index:i,snippet:content.slice(Math.max(0,i-125),i+175)});
 }
}
console.log(JSON.stringify(result));
'@
 $jsfile=Join-Path $toolsRoot 'inspect-goose.cjs'
 [IO.File]::WriteAllText($jsfile,$js,(New-Object Text.UTF8Encoding($false)))
 $stdout=Join-Path $toolsRoot 'asar-inspection.json'
 $stderr=Join-Path $toolsRoot 'asar-inspection-errors.log'
 $p=Start-Process -FilePath $node.Source -ArgumentList @($jsfile) -WorkingDirectory $toolsRoot -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
 if(-not $p.WaitForExit(25000)){try{$p.Kill()}catch{};throw 'Asar inventory exceeded 25 seconds'}
 if($p.ExitCode -ne 0){throw ('ASAR inspect failed: '+(Get-Content $stderr -Tail 6|Out-String))}
 $info=Get-Content $stdout -Raw|ConvertFrom-Json
 $r.files=@($info.files)
 $r.interesting=@($info.main)
 $r.english_attach_files=@($info.attach)
 $r.status='success'
 $r.error='node='+$r.node_version+' archive_files='+$info.file_count+' js_files='+$info.js_count+' main_count='+$r.interesting.Count+' attach_count='+$r.english_attach_files.Count+' main='+($r.interesting|ForEach-Object{$_.path+':'+$_.index+' '+$_.snippet}|Select-Object -First 1)+' attach='+($r.english_attach_files|ForEach-Object{$_.path+':'+$_.index+' '+$_.snippet}|Select-Object -First 2)
}catch{$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 8|Set-Content $GatewayResultPath -Encoding UTF8
exit 0
