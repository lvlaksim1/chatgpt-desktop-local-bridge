[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$exe=Join-Path $root 'bin\goose.exe'
$work=Join-Path $root 'workspace'
$logs=Join-Path $root 'logs'
$report=[ordered]@{status='failed';error='';config_path='';provider='ollama_local_no_stream';model='qwen3.5:4b-goose';response='';exit_code='';seconds=0}
$start=[DateTime]::UtcNow
try{
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Goose CLI missing'}
 $configDir=Join-Path $env:APPDATA 'Block\goose\config\custom_providers'
 New-Item -ItemType Directory -Force -Path $configDir|Out-Null
 $configPath=Join-Path $configDir 'ollama_local_no_stream.json'
 $config=@{
  name='ollama_local_no_stream'
  engine='openai'
  display_name='Local Ollama (non-stream)'
  description='Local offline Ollama OpenAI-compatible provider with non-streaming results'
  base_url='http://127.0.0.1:11434/v1/chat/completions'
  models=@(@{name='qwen3.5:4b-goose';context_limit=8192})
  supports_streaming=$false
  requires_auth=$false
 }
 $config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath -Encoding UTF8
 $report.config_path=$configPath
 $env:GOOSE_PROVIDER='ollama_local_no_stream'
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:GOOSE_MODE='chat'
 $env:GOOSE_CONTEXT_LIMIT='8192'
 $env:GOOSE_MAX_TOKENS='256'
 $env:NO_COLOR='1'
 $out=Join-Path $logs 'nonstream-goose.stdout.log'
 $err=Join-Path $logs 'nonstream-goose.stderr.log'
 $args='run --provider ollama_local_no_stream --model qwen3.5:4b-goose --no-session --max-turns 2 --quiet --text "/no_think Reply with exactly the word GOOSEREADY"'
 $p=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
 $done=$p.WaitForExit(105000)
 if(-not $done){try{$p.Kill()}catch{};throw 'Non-streaming Goose test timed out after 105 seconds'}
 $report.exit_code=[string]$p.ExitCode
 $text=(Get-Content -LiteralPath $out -Tail 25|Out-String).Trim()
 $stderr=(Get-Content -LiteralPath $err -Tail 25|Out-String).Trim()
 if($text.Length -gt 450){$text=$text.Substring($text.Length-450)}
 if($stderr.Length -gt 450){$stderr=$stderr.Substring($stderr.Length-450)}
 $report.response=$text
 if($p.ExitCode -ne 0){throw ('Goose nonstream returned '+$p.ExitCode+': '+$stderr)}
 if($text -notmatch 'GOOSEREADY'){throw ('Goose nonstream returned unexpected response: '+$text+' ; stderr='+$stderr)}
 $report.status='success'
 $report.error='Goose completed the local Ollama chat via a non-streaming OpenAI-compatible provider.'
}catch{$report.error=[string]$_.Exception.Message}
$report.seconds=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
