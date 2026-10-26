param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$configRoot=Join-Path $root 'openai-compat-isolated'
$configDir=Join-Path $configRoot 'config\custom_providers'
$exe=Join-Path $root 'bin\goose.exe'
$work=Join-Path $root 'workspace'
$logs=Join-Path $root 'logs'
$id='custom_ollama_nonstream'
$r=[ordered]@{status='failed';error='';config='';no_bom=$false;exit_code=$null;response='';stderr='';duration_sec=0;api_ok=$false}
$started=[DateTime]::UtcNow
try{
 foreach($d in @($configDir,$work,$logs)){New-Item -ItemType Directory -Path $d -Force|Out-Null}
 $null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 5
 $r.api_ok=$true
 $conf=[ordered]@{
  name=$id
  engine='openai'
  display_name='Local Ollama without streaming'
  description='Offline Ollama using compatible API'
  api_key_env=''
  base_url='http://127.0.0.1:11434/v1/chat/completions'
  models=@(@{name='qwen3.5:4b-goose';context_limit=8192})
  headers=$null
  timeout_seconds=110
  supports_streaming=$false
  requires_auth=$false
  dynamic_models=$false
  preserves_thinking=$false
 }
 $file=Join-Path $configDir ($id+'.json')
 $j=ConvertTo-Json -InputObject $conf -Depth 12
 [IO.File]::WriteAllText($file,$j,(New-Object System.Text.UTF8Encoding($false)))
 $r.config=$file
 $b=[IO.File]::ReadAllBytes($file)
 $r.no_bom=(-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191))
 if(-not $r.no_bom){throw 'JSON config unexpectedly has BOM'}
 $env:GOOSE_PATH_ROOT=$configRoot
 $env:GOOSE_PROVIDER=$id
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:GOOSE_MODE='chat'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:NO_COLOR='1'
 $out=Join-Path $logs 'goose-bomfree.stdout.log'
 $err=Join-Path $logs 'goose-bomfree.stderr.log'
 $args='run --no-profile --no-session --provider '+$id+' --model qwen3.5:4b-goose --max-turns 2 --quiet --text "Reply with exactly the word GOOSEREADY"'
 $p=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
 if(-not $p.WaitForExit(115000)){try{$p.Kill()}catch{};throw 'Goose timed out after 115 seconds'}
 $p.Refresh()
 $r.exit_code=$p.ExitCode
 $t=(Get-Content -LiteralPath $out -Tail 20 -ErrorAction SilentlyContinue|Out-String).Trim()
 $e=(Get-Content -LiteralPath $err -Tail 15 -ErrorAction SilentlyContinue|Out-String).Trim()
 if($t.Length -gt 350){$t=$t.Substring($t.Length-350)}
 if($e.Length -gt 400){$e=$e.Substring($e.Length-400)}
 $r.response=$t
 $r.stderr=$e
 if($t -notmatch 'GOOSEREADY'){throw ('No expected reply. stdout='+$t+' stderr='+$e)}
 $r.status='success'
 $r.error='Goose responded through a local nonstream OpenAI-compatible provider.'
}catch{
 $r.error=[string]$_.Exception.Message
}
$r.duration_sec=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1)
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
