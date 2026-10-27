param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$r=[ordered]@{status='failed';stage='start';error='';parameters='';modified_launchers=@();already_fixed=$false}
try{
 $root='D:\LocalAI\Goose'
 $url='http://127.0.0.1:11434'
 $logs=Join-Path $root 'logs'
 $backups=Join-Path $root 'backups'
 New-Item -ItemType Directory -Path $logs,$backups -Force|Out-Null
 $r.stage='api'
 $version=Invoke-RestMethod -Uri ($url+'/api/version') -TimeoutSec 8
 $showBody='{"model":"qwen3.5:4b-goose"}'
 $before=Invoke-RestMethod -Uri ($url+'/api/show') -Method Post -ContentType 'application/json' -Body $showBody -TimeoutSec 10
 [IO.File]::WriteAllText((Join-Path $logs 'goose-output-model-before.json'),($before|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($false)))
 $r.stage='model'
 $already=([string]$before.parameters -match '(?m)^\s*num_predict\s+-1\s*$')
 $r.already_fixed=$already
 if(-not $already){
  $payload=@{model='qwen3.5:4b-goose';from='qwen3.5:4b';parameters=@{num_ctx=8192;num_predict=-1};stream=$false}|ConvertTo-Json -Depth 8 -Compress
  $null=Invoke-RestMethod -Uri ($url+'/api/create') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 80
 }
 $after=Invoke-RestMethod -Uri ($url+'/api/show') -Method Post -ContentType 'application/json' -Body $showBody -TimeoutSec 12
 $r.parameters=[string]$after.parameters
 if($r.parameters -notmatch '(?m)^\s*num_predict\s+-1\s*$'){throw 'Ollama did not persist num_predict -1'}
 $r.stage='launchers'
 foreach($name in @('Goose-RU.cmd','Goose-Agent.cmd','Goose-Chat.cmd')){
  $file=Join-Path $root $name
  if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw ('Launcher missing: '+$name)}
  $original=@(Get-Content -LiteralPath $file)
  $updated=@()
  $added=0
  foreach($line in $original){
   if($line -match '(?i)^\s*set\s+"GOOSE_MAX_TOKENS='){continue}
   $updated+= $line
   if($line -match '(?i)^\s*set\s+"GOOSE_MODEL='){
    $updated+='set "GOOSE_MAX_TOKENS=8192"'
    $added++
   }
  }
  if($added -ne 1){throw ('Invalid model setting anchor: '+$name)}
  $bak=Join-Path $backups ($name+'.before-max-output-v4')
  if(-not(Test-Path -LiteralPath $bak)){Copy-Item -LiteralPath $file -Destination $bak}
  [IO.File]::WriteAllLines($file,$updated,[Text.Encoding]::ASCII)
  $check=@(Get-Content -LiteralPath $file|Where-Object{$_ -eq 'set "GOOSE_MAX_TOKENS=8192"'})
  if($check.Count -ne 1){throw ('Failed to verify launcher '+$name)}
  $r.modified_launchers+= $name
 }
 $r.stage='complete'
 $r.status='success'
 $r.error='num_predict=-1; GOOSE_MAX_TOKENS=8192 in all three launchers. Close all Goose windows and relaunch for environment changes.'
}catch{$r.error=([string]$_.Exception.Message -replace '[\r\n]+',' ')}
if($r.error.Length -gt 600){$r.error=$r.error.Substring(0,600)}
$r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
