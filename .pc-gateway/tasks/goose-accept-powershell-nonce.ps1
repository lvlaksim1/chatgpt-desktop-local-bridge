param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$work=Join-Path $root 'workspace\acceptance'
$exe=Join-Path $root 'bin\goose.exe'
$r=[ordered]@{status='failed';error='';exit_code=$null;stdout='';stderr='';shell_file_exists=$false;content_matches=$false;powershell_seen_in_trace=$false;duration_sec=0}
$start=[DateTime]::UtcNow
try {
 New-Item -ItemType Directory -Path $work -Force|Out-Null
 $target=Join-Path $work 'nonce_verified.txt'
 if(Test-Path $target){Remove-Item -LiteralPath $target -Force}
 $nonce=[Guid]::NewGuid().ToString('N')
 $env:GOOSE_PROBE_NONCE=$nonce
 $env:HTTP_PROXY=''
 $env:HTTPS_PROXY=''
 $env:ALL_PROXY=''
 $env:NO_PROXY='localhost,127.0.0.1,::1'
 $env:GOOSE_PATH_ROOT='D:\LocalAI\Goose\stage1-isolated'
 $env:GOOSE_PROVIDER='ollama'
 $env:GOOSE_MODEL='qwen3.5:4b-goose'
 $env:GOOSE_MODE='auto'
 $env:GOOSE_INPUT_LIMIT='8192'
 $env:OLLAMA_HOST='http://127.0.0.1:11434'
 $env:OLLAMA_STREAM_USAGE='false'
 $env:GOOSE_DISABLE_KEYRING='1'
 $env:NO_COLOR='1'
 $psi=New-Object System.Diagnostics.ProcessStartInfo
 $psi.FileName=$exe
 $psi.Arguments='run --no-profile --with-builtin developer --no-session --provider ollama --model qwen3.5:4b-goose --max-turns 4 --quiet --text "Use your shell tool to run powershell.exe and write the value of environment variable GOOSE_PROBE_NONCE into nonce_verified.txt in the current directory. Do not guess the value. Do not use a file editing tool. Then say SHELL_DONE."'
 $psi.WorkingDirectory=$work
 $psi.UseShellExecute=$false
 $psi.RedirectStandardOutput=$true
 $psi.RedirectStandardError=$true
 $psi.CreateNoWindow=$true
 $p=New-Object System.Diagnostics.Process
 $p.StartInfo=$psi
 if(-not $p.Start()){throw 'Goose did not start'}
 $a=$p.StandardOutput.ReadToEndAsync()
 $b=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(130000)){try{$p.Kill()}catch{};throw 'PowerShell tool check timed out at 130s'}
 $r.exit_code=$p.ExitCode
 $o=[string]$a.GetAwaiter().GetResult()
 $e=[string]$b.GetAwaiter().GetResult()
 if($o.Length -gt 360){$o=$o.Substring($o.Length-360)}
 if($e.Length -gt 360){$e=$e.Substring($e.Length-360)}
 $r.stdout=$o.Trim()
 $r.stderr=$e.Trim()
 $r.shell_file_exists=Test-Path -LiteralPath $target -PathType Leaf
 if($r.shell_file_exists){$r.content_matches=([IO.File]::ReadAllText($target).Trim() -eq $nonce)}
 $logs=Join-Path $env:GOOSE_PATH_ROOT 'data\logs'
 if(Test-Path $logs){
  $trace=@(Get-ChildItem $logs -File -Filter 'llm_request*.jsonl' -ErrorAction SilentlyContinue|Where-Object{$_.LastWriteTimeUtc -ge $start.AddSeconds(-3)})
  foreach($f in $trace){
   if(Select-String -LiteralPath $f.FullName -SimpleMatch 'powershell.exe' -Quiet -ErrorAction SilentlyContinue){$r.powershell_seen_in_trace=$true;break}
  }
 }
 if($r.content_matches -and $r.exit_code -eq 0){
  $r.status='success'
  $r.error='Goose recovered an unpredictable environment nonce through a shell tool and wrote the matching file.'
 }else{
  $r.error='PowerShell not fully verified: file='+$r.shell_file_exists+' match='+$r.content_matches+' trace='+$r.powershell_seen_in_trace+' exit='+$r.exit_code+' stderr='+$r.stderr
 }
}catch{$r.error=[string]$_.Exception.Message+'; output='+$r.stdout+'; stderr='+$r.stderr+'; file='+$r.shell_file_exists}
$r.duration_sec=[math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,1)
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
