param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$log=Join-Path $root 'logs'
$backup=Join-Path $root 'backups'
$r=[ordered]@{status='failed';stage='preflight';error='';model='qwen3.5:4b-goose';model_parameters='';launchers=@();response_tokens=0;response_reason='';output_more_than_256=$false;original_models_unchanged=$true}
try {
 New-Item -ItemType Directory -Path $log,$backup -Force|Out-Null
 $api='http://127.0.0.1:11434'
 $null=Invoke-RestMethod -Uri ($api+'/api/version') -Method Get -TimeoutSec 8
 $tags=Invoke-RestMethod -Uri ($api+'/api/tags') -TimeoutSec 8
 $names=@($tags.models|ForEach-Object{[string]$_.name})
 foreach($model in @('qwen3.5:4b','qwen3.5:9b','qwen3.5:4b-goose')){if($names -notcontains $model){throw ('Missing Ollama model: '+$model)}}
 $r.stage='model'
 $showPayload=@{model='qwen3.5:4b-goose'}|ConvertTo-Json -Compress
 $previous=Invoke-RestMethod -Uri ($api+'/api/show') -Method Post -ContentType 'application/json' -Body $showPayload -TimeoutSec 15
 [IO.File]::WriteAllText((Join-Path $log 'qwen4b-goose-before-unlimited.json'),($previous|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($false)))
 $payload=@{model='qwen3.5:4b-goose';from='qwen3.5:4b';parameters=@{num_ctx=8192;num_predict=-1};stream=$false}|ConvertTo-Json -Depth 10 -Compress
 $null=Invoke-RestMethod -Uri ($api+'/api/create') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 90
 $current=Invoke-RestMethod -Uri ($api+'/api/show') -Method Post -ContentType 'application/json' -Body $showPayload -TimeoutSec 15
 $r.model_parameters=[string]$current.parameters
 if($r.model_parameters -notmatch '(?m)^\s*num_predict\s+-1\s*$'){throw ('Unlimited output setting is absent in Ollama model: '+$r.model_parameters)}
 if($r.model_parameters -notmatch '(?m)^\s*num_ctx\s+8192\s*$'){throw ('Expected context setting missing: '+$r.model_parameters)}
 $r.stage='launchers'
 foreach($name in @('Goose-RU.cmd','Goose-Agent.cmd','Goose-Chat.cmd')){
  $p=Join-Path $root $name
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Launcher not found: '+$p)}
  $lines=@(Get-Content -LiteralPath $p)
  $found=@($lines|Where-Object{$_ -match '^\s*set\s+"GOOSE_MAX_TOKENS='})
  if($found.Count -gt 1){throw ('Duplicate GOOSE_MAX_TOKENS settings in '+$name)}
  $exists=$false
  for($i=0;$i -lt $lines.Count;$i++){
   if($lines[$i] -match '^\s*set\s+"GOOSE_MAX_TOKENS='){
    $lines[$i]='set "GOOSE_MAX_TOKENS=8192"'
    $exists=$true
   }
  }
  if(-not $exists){
   $idx=-1
   for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^\s*set\s+"GOOSE_INPUT_LIMIT='){ $idx=$i;break}}
   if($idx -lt 0){throw ('Expected input limit anchor not found in '+$name)}
   $tmp=New-Object 'System.Collections.Generic.List[string]'
   for($i=0;$i -lt $lines.Count;$i++){
    $tmp.Add($lines[$i])
    if($i -eq $idx){$tmp.Add('set "GOOSE_MAX_TOKENS=8192"')}
   }
   $lines=@($tmp.ToArray())
  }
  $backupPath=Join-Path $backup ($name+'.before-output-unlimit')
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){Copy-Item -LiteralPath $p -Destination $backupPath}
  [IO.File]::WriteAllLines($p,$lines,[Text.Encoding]::ASCII)
  $check=@(Get-Content -LiteralPath $p|Where-Object{$_ -eq 'set "GOOSE_MAX_TOKENS=8192"'})
  if($check.Count -ne 1){throw ('Launcher output limit not written reliably in '+$name)}
  $r.launchers+=($name+':8192')
 }
 $r.stage='probe'
 # No artificial max-token cap in this request; measure naturally generated response.
 # Keep one verification request bounded in time, not in generation length.
 $probe='Напиши по-русски пронумерованный список из 65 отдельных практических советов по работе с текстовыми файлами. Каждый пункт состоит минимум из 12 слов. Не объединяй пункты и не сокращай список.'
 $body=@{model='qwen3.5:4b-goose';prompt=$probe;stream=$false;think=$false;options=@{num_ctx=8192;temperature=0.2}}|ConvertTo-Json -Depth 10 -Compress
 try{
  $out=Invoke-RestMethod -Uri ($api+'/api/generate') -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 175
  $r.response_tokens=[int]$out.eval_count
  $r.response_reason=[string]$out.done_reason
  $r.output_more_than_256=($r.response_tokens -gt 256)
  if(-not $r.output_more_than_256){throw ('Model output still limited; generated '+$r.response_tokens+' tokens, done_reason='+$r.response_reason)}
 }catch{
  if($r.response_tokens -eq 0){$r.error='Output cap updated and launchers patched; long-response probe was inconclusive: '+[string]$_.Exception.Message}
  else{$r.error='Output cap updated; probe did not demonstrate >256 tokens: '+[string]$_.Exception.Message}
 }
 if($r.error){$r.status='partial';$r.stage='probe';}
 else{$r.status='success';$r.stage='done';$r.error='Removed model num_predict=256 cap; Goose now requests up to 8192 output tokens; direct Ollama probe generated more than 256 tokens.'}
}catch{$r.error=([string]$_.Exception.Message -replace '[\r\n\t]+',' ')}
if($r.error.Length -gt 640){$r.error=$r.error.Substring(0,640)}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
