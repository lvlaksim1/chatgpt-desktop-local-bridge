[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
 [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$exe=Join-Path $root 'bin\goose.exe'
$work=Join-Path $root 'workspace'
$logs=Join-Path $root 'logs'
$dir=Join-Path $root 'config\custom_providers'
$id='custom_ollama_local_no_stream'
$report=[ordered]@{status='failed';stage='preflight';error='';provider=$id;config_file='';exit_code=$null;seconds=0;stdout='';stderr='';api_available=$false;response_verified=$false}
$start=[DateTime]::UtcNow
try{
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Goose CLI binary missing'}
 $null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 7
 $report.api_available=$true
 foreach($p in @($work,$logs,$dir)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
 $report.stage='config'
 $config=[ordered]@{
  name=$id
  engine='openai'
  display_name='Local Offline Ollama'
  description='Local non-stream OpenAI-compatible Ollama, no remote credentials'
  api_key_env=''
  base_url='http://127.0.0.1:11434/v1/chat/completions'
  models=@(@{name='qwen3.5:4b-goose';context_limit=8192})
  headers=$null
  timeout_seconds=100
  supports_streaming=$false
  requires_auth=$false
  dynamic_models=$false
  preserves_thinking=$false
  emit_clear_thinking=$false
 }
 $dest=Join-Path $dir ($id+'.json')
 $config|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $dest -Encoding UTF8
 $report.config_file=$dest
 $env:GOOSE_PATH_ROOT=$root
 $env:GOOSE_PROVIDER=$id
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:GOOSE_MODE='chat'
 $env:GOOSE_INPUT_LIMIT='8192'
 $env:NO_COLOR='1'
 $report.stage='goose'
 $out=Join-Path $logs 'provider-repair.stdout.log'
 $err=Join-Path $logs 'provider-repair.stderr.log'
 $args='run --provider '+$id+' --model qwen3.5:4b-goose --no-session --max-turns 2 --quiet --text "/no_think Reply with exactly GOOSEREADY"'
 $proc=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
 $done=$proc.WaitForExit(112000)
 if(-not $done){try{$proc.Kill()}catch{};throw 'Goose custom-provider smoke test timed out at 112 seconds'}
 $proc.Refresh()
 $report.exit_code=$proc.ExitCode
 $o=(Get-Content -LiteralPath $out -Tail 26 -ErrorAction SilentlyContinue|Out-String).Trim()
 $e=(Get-Content -LiteralPath $err -Tail 26 -ErrorAction SilentlyContinue|Out-String).Trim()
 if($o.Length -gt 460){$o=$o.Substring($o.Length-460)}
 if($e.Length -gt 460){$e=$e.Substring($e.Length-460)}
 $report.stdout=$o
 $report.stderr=$e
 if($o -notmatch 'GOOSEREADY'){throw ('No expected response; goose output='+$o+'; stderr='+$e)}
 $report.response_verified=$true
 if($proc.ExitCode -ne 0){throw ('Goose returned unexpected exit code '+$proc.ExitCode)}
 $report.status='success'
 $report.stage='complete'
 $report.error='Goose custom OpenAI-compatible non-stream provider worked with local Qwen.'
}catch{
 $report.error=[string]$_.Exception.Message
}
$report.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
if($report.error.Length -gt 680){$report.error=$report.error.Substring(0,680)}
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
if(Test-Path $logs){$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $logs 'provider-repair-result.json') -Encoding UTF8}
exit 0
