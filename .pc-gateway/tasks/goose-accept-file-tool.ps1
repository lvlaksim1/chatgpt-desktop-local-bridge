param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$work=Join-Path $root 'workspace\acceptance'
$exe=Join-Path $root 'bin\goose.exe'
$r=[ordered]@{status='failed';error='';output='';stderr='';exit_code=$null;file_created=$false;file_matches=$false;duration_sec=0}
$t=[DateTime]::UtcNow
try{
 New-Item -ItemType Directory -Path $work -Force | Out-Null
 $input=Join-Path $work 'acceptance_input.txt'
 $target=Join-Path $work 'acceptance_output.txt'
 [IO.File]::WriteAllText($input,'LOCAL_GOOSE_FILE_TEST_2710',(New-Object System.Text.UTF8Encoding($false)))
 if(Test-Path $target){Remove-Item -LiteralPath $target -Force}
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
 $psi.Arguments='run --no-profile --with-builtin developer --no-session --provider ollama --model qwen3.5:4b-goose --max-turns 4 --quiet --text "Read acceptance_input.txt using your file tools. Create acceptance_output.txt in the same directory with exactly the same text. Do not modify other files. Then say FILE_DONE."'
 $psi.WorkingDirectory=$work
 $psi.UseShellExecute=$false
 $psi.RedirectStandardOutput=$true
 $psi.RedirectStandardError=$true
 $psi.CreateNoWindow=$true
 $p=New-Object System.Diagnostics.Process
 $p.StartInfo=$psi
 if(-not $p.Start()){throw 'Goose process did not start'}
 $stdoutTask=$p.StandardOutput.ReadToEndAsync()
 $stderrTask=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(135000)){
  try{$p.Kill()}catch{}
  [void]$p.WaitForExit(5000)
  throw 'Goose file-tool check timed out after 135 seconds'
 }
 $r.exit_code=$p.ExitCode
 $output=[string]$stdoutTask.GetAwaiter().GetResult()
 $stderr=[string]$stderrTask.GetAwaiter().GetResult()
 if($output.Length -gt 350){$output=$output.Substring($output.Length-350)}
 if($stderr.Length -gt 350){$stderr=$stderr.Substring($stderr.Length-350)}
 $r.output=$output.Trim()
 $r.stderr=$stderr.Trim()
 $r.file_created=Test-Path -LiteralPath $target -PathType Leaf
 if($r.file_created){$r.file_matches=((Get-Content -LiteralPath $target -Raw).Trim() -eq 'LOCAL_GOOSE_FILE_TEST_2710')}
 if($r.file_matches -and $r.exit_code -eq 0){$r.status='success';$r.error='Goose used a tool to produce the verified output file.'}
 else{$r.error='No verified tool output; exit='+$r.exit_code+' output='+$r.output+' stderr='+$r.stderr+' file_created='+$r.file_created+' matches='+$r.file_matches}
}catch{$r.error=[string]$_.Exception.Message}
$r.duration_sec=[math]::Round(([DateTime]::UtcNow-$t).TotalSeconds,1)
if($r.error.Length -gt 690){$r.error=$r.error.Substring(0,690)}
$r|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
