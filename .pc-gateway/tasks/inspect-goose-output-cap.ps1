param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$r=[ordered]@{status='diagnostic';error='';parser_errors='';model_parameters='';launchers='';backup_exists=$false;ollama_ok=$false}
try {
 $target=Join-Path $PSScriptRoot 'remove-goose-output-cap.ps1'
 $tokens=$null
 $errors=$null
 $a=[Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$errors)
 if(@($errors).Count){$r.parser_errors=(@($errors)|Select-Object -First 3|ForEach-Object{$_.Message+'@line'+$_.Extent.StartLineNumber}) -join ' ; '}
 else{$r.parser_errors='none'}
 try{
  $body='{"model":"qwen3.5:4b-goose"}'
  $info=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/show' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 8
  $r.model_parameters=[string]$info.parameters
  $r.ollama_ok=$true
 }catch{$r.model_parameters='API error '+$_.Exception.Message}
 $root='D:\LocalAI\Goose'
 $checks=@()
 foreach($n in @('Goose-RU.cmd','Goose-Agent.cmd','Goose-Chat.cmd')){
  $p=Join-Path $root $n
  if(Test-Path $p){$checks+=($n+':'+(@(Get-Content $p|Where-Object{$_ -match 'GOOSE_MAX_TOKENS'} ) -join ','))}
  else{$checks+=($n+':missing')}
 }
 $r.launchers=$checks -join ' | '
 $r.backup_exists=Test-Path 'D:\LocalAI\Goose\logs\qwen4b-goose-before-unlimited.json'
 $r.error='parser='+$r.parser_errors+'; model='+($r.model_parameters -replace '[\r\n]+',',')+'; launchers='+$r.launchers+'; backup='+$r.backup_exists
}catch{$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
