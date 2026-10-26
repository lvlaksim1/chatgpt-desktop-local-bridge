[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$bin=Join-Path $root 'bin\goose.exe'
$work=Join-Path $root 'workspace'
$logs=Join-Path $root 'logs'
$report=[ordered]@{status='failed';stage='preflight';error='';binary_exists=$false;ollama_api=$false;version='';exit_code=$null;seconds=0;output_tail='';stderr_tail='';model='qwen3.5:4b-goose';provider='ollama'}
$started=[DateTime]::UtcNow
try{
 $report.binary_exists=(Test-Path -LiteralPath $bin -PathType Leaf)
 if(-not $report.binary_exists){throw 'Goose binary missing'}
 $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 6
 $report.ollama_api=$true
 $report.stage='test'
 $env:GOOSE_PROVIDER='ollama'
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:OLLAMA_HOST='http://127.0.0.1:11434'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:GOOSE_CONTEXT_LIMIT='8192'
 $env:GOOSE_INPUT_LIMIT='8192'
 $env:GOOSE_MODE='chat'
 $env:NO_COLOR='1'
 $stdout=Join-Path $logs 'goose-no-tools-chat-stdout.log'
 $stderr=Join-Path $logs 'goose-no-tools-chat-stderr.log'
 $args='run --no-session --provider ollama --model qwen3.5:4b-goose --max-turns 2 --quiet --text "Reply with exactly one word: GOOSEREADY"'
 $p=Start-Process -FilePath $bin -ArgumentList $args -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
 $completed=$p.WaitForExit(150000)
 if(-not $completed){
  try{$p.Kill()}catch{}
  throw 'Goose CLI chat exceeded 150 second timeout and was terminated'
 }
 $report.exit_code=[int]$p.ExitCode
 $output=if(Test-Path $stdout){(Get-Content -LiteralPath $stdout -Tail 30|Out-String).Trim()}else{''}
 $errText=if(Test-Path $stderr){(Get-Content -LiteralPath $stderr -Tail 24|Out-String).Trim()}else{''}
 if($output.Length -gt 550){$output=$output.Substring($output.Length-550)}
 if($errText.Length -gt 550){$errText=$errText.Substring($errText.Length-550)}
 $report.output_tail=$output
 $report.stderr_tail=$errText
 if($p.ExitCode -ne 0){throw ('goose run failed (exit '+$p.ExitCode+'): '+$errText)}
 if($output -notmatch 'GOOSEREADY'){throw ('No GOOSEREADY confirmation in Goose response: '+$output)}
 $report.status='success'
 $report.stage='completed'
 $report.error='Goose CLI connected to local Ollama and completed a model response.'
}catch{$report.error=[string]$_.Exception.Message}
$report.seconds=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1)
if($report.error.Length -gt 680){$report.error=$report.error.Substring(0,680)}
$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
if(Test-Path $logs){$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $logs 'chat-no-tools-test-result.json') -Encoding UTF8}
exit 0
