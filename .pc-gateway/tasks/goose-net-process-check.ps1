param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$exe=Join-Path $root 'bin\goose.exe'
$work=Join-Path $root 'workspace'
$r=[ordered]@{status='failed';error='';exit_code=$null;elapsed=0;output='';stderr='';timed_out=$false;proxy_was_set=$false}
$t=[DateTime]::UtcNow
try{
 $r.proxy_was_set=[bool]($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY)
 $env:HTTP_PROXY=''
 $env:HTTPS_PROXY=''
 $env:ALL_PROXY=''
 $env:NO_PROXY='localhost,127.0.0.1,::1'
 $env:GOOSE_PATH_ROOT='D:\LocalAI\Goose\stage1-isolated'
 $env:GOOSE_PROVIDER='ollama'
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:GOOSE_MODE='chat'
 $env:GOOSE_INPUT_LIMIT='4096'
 $env:OLLAMA_HOST='http://127.0.0.1:11434'
 $env:OLLAMA_STREAM_USAGE='false'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:NO_COLOR='1'
 $psi=New-Object System.Diagnostics.ProcessStartInfo
 $psi.FileName=$exe
 $psi.Arguments='run --no-profile --no-session --provider ollama --model qwen3.5:4b-goose --max-turns 2 --quiet --text "Reply exactly GOOSEREADY"'
 $psi.WorkingDirectory=$work
 $psi.UseShellExecute=$false
 $psi.RedirectStandardOutput=$true
 $psi.RedirectStandardError=$true
 $psi.CreateNoWindow=$true
 $p=New-Object System.Diagnostics.Process
 $p.StartInfo=$psi
 if(-not $p.Start()){throw 'Failed starting Goose process'}
 $outTask=$p.StandardOutput.ReadToEndAsync()
 $errTask=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(105000)){
  $r.timed_out=$true
  try{$p.Kill()}catch{}
  [void]$p.WaitForExit(4000)
 }
 $r.exit_code=$p.ExitCode
 $stdout=[string]$outTask.GetAwaiter().GetResult()
 $stderr=[string]$errTask.GetAwaiter().GetResult()
 if($stdout.Length -gt 400){$stdout=$stdout.Substring($stdout.Length-400)}
 if($stderr.Length -gt 400){$stderr=$stderr.Substring($stderr.Length-400)}
 $r.output=$stdout.Trim()
 $r.stderr=$stderr.Trim()
 if($r.output -match 'GOOSEREADY' -and -not $r.timed_out){
  $r.status='success'
  $r.error='Goose responded through local Ollama; exit_code='+$r.exit_code
 }else{
  $r.error='No confirmed response; exit='+$r.exit_code+' output='+$r.output+' stderr='+$r.stderr+' timed_out='+$r.timed_out
 }
}catch{$r.error=[string]$_.Exception.Message}
$r.elapsed=[math]::Round(([DateTime]::UtcNow-$t).TotalSeconds,1)
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
