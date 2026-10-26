param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$work=Join-Path $root 'workspace'
$profile=Join-Path $root 'profile'
$backups=Join-Path $root 'backups'
$exe=Join-Path $root 'bin\goose.exe'
$r=[ordered]@{status='failed';error='';agent_launcher='';chat_launcher='';legacy_launcher='';profile='';files_verified=$false;ollama_ok=$false;goose_binary_ok=$false}
try{
 if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'goose.exe missing'}
 foreach($p in @($work,$profile,$backups)){New-Item -ItemType Directory -Path $p -Force|Out-Null}
 $null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 5 -Method Get
 $r.ollama_ok=$true
 $common=@(
  '@echo off',
  'setlocal',
  'set "HTTP_PROXY="',
  'set "HTTPS_PROXY="',
  'set "ALL_PROXY="',
  'set "NO_PROXY=localhost,127.0.0.1,::1"',
  'set "GOOSE_PATH_ROOT=D:\LocalAI\Goose\profile"',
  'set "OLLAMA_HOST=http://127.0.0.1:11434"',
  'set "GOOSE_PROVIDER=ollama"',
  'set "GOOSE_MODEL=qwen3.5:4b-goose"',
  'set "GOOSE_INPUT_LIMIT=8192"',
  'set "OLLAMA_STREAM_USAGE=false"',
  'set "GOOSE_DISABLE_KEYRING=1"',
  'cd /d "D:\LocalAI\Goose\workspace"'
 )
 $chat=Join-Path $root 'Goose-Chat.cmd'
 $agent=Join-Path $root 'Goose-Agent.cmd'
 $legacy=Join-Path $root 'Goose-Local-4B.cmd'
 if(Test-Path -LiteralPath $legacy -PathType Leaf){
  $backup=Join-Path $backups 'Goose-Local-4B.before-working-fix.cmd'
  if(-not (Test-Path $backup)){Copy-Item -LiteralPath $legacy -Destination $backup}
 }
 $agentLines=@($common)+@(
  'set "GOOSE_MODE=approve"',
  'echo Goose Agent - Local Qwen3.5 4B (confirm tool actions)',
  '"D:\LocalAI\Goose\bin\goose.exe" session --no-profile --with-builtin developer',
  'echo.',
  'pause'
 )
 $chatLines=@($common)+@(
  'set "GOOSE_MODE=chat"',
  'echo Goose Chat - Local Qwen3.5 4B (no tools)',
  '"D:\LocalAI\Goose\bin\goose.exe" session --no-profile',
  'echo.',
  'pause'
 )
 [IO.File]::WriteAllLines($agent,$agentLines,[Text.Encoding]::ASCII)
 [IO.File]::WriteAllLines($chat,$chatLines,[Text.Encoding]::ASCII)
 [IO.File]::WriteAllLines($legacy,@('@echo off','call "%~dp0Goose-Agent.cmd"'),[Text.Encoding]::ASCII)
 $r.agent_launcher=$agent
 $r.chat_launcher=$chat
 $r.legacy_launcher=$legacy
 $r.profile=$profile
 $readme=Join-Path $root 'README-local-agent.txt'
 $doc=@'
Goose 1.56.0 + Ollama Qwen3.5 4B on this Windows PC

Goose-Chat.cmd  - chat without tools.
Goose-Agent.cmd - agent with built-in developer tools; asks for approval.
Goose-Local-4B.cmd - compatibility shortcut to Goose-Agent.cmd.

All models stay in D:\LocalAI\Ollama\models.
Ollama must be running on http://127.0.0.1:11434.
Goose working directory: D:\LocalAI\Goose\workspace
Goose profile: D:\LocalAI\Goose\profile

Local proxy bypass in launchers is intentionally set only for the
launched Goose process; Windows system proxy settings are not changed.
Do not switch agent into automatic approval for untrusted directories.
'@
 [IO.File]::WriteAllText($readme,$doc,(New-Object System.Text.UTF8Encoding($false)))
 $r.files_verified=(Test-Path $agent) -and (Test-Path $chat) -and (Test-Path $legacy)
 $version=(& $exe --version 2>&1 | Out-String).Trim()
 $r.goose_version=$version
 $r.goose_binary_ok=($LASTEXITCODE -eq 0)
 if(-not $r.files_verified -or -not $r.goose_binary_ok){throw 'Verification failed'}
 $r.status='success'
 $r.error='Created two launchers using tested local proxy bypass; agent requires approval; previous launcher backed up.'
}catch{$r.error=[string]$_.Exception.Message}
$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
