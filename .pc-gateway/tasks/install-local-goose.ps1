[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'
$root='D:\LocalAI\Goose'
$bin=Join-Path $root 'bin'
$downloads=Join-Path $root 'downloads'
$logs=Join-Path $root 'logs'
$work=Join-Path $root 'workspace'
$version='v1.56.0'
$file='goose-x86_64-pc-windows-msvc.zip'
$sha='76fbb942579f5851b6593ab0f97b7bd7317d700132443dfa37aa1cddb8af04da'
$url='https://github.com/aaif-goose/goose/releases/download/'+$version+'/'+$file
$zip=Join-Path $downloads $file
$exe=Join-Path $bin 'goose.exe'
$report=[ordered]@{status='failed';stage='preflight';error='';version=$version;binary=$exe;workspace=$work;sha256=$sha;downloaded=$false;verified=$false;goose_version='';ollama_api_ok=$false;launcher=''}
try {
  foreach($p in @($root,$bin,$downloads,$logs,$work)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
  $report.stage='ollama'
  $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 6
  $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 6
  $names=@($tags.models|ForEach-Object{[string]$_.name})
  if($names -notcontains 'qwen3.5:4b'){throw 'Ollama model qwen3.5:4b is missing'}
  $report.ollama_api_ok=$true
  $report.stage='download'
  if(-not (Test-Path -LiteralPath $zip -PathType Leaf)){
    $temp=$zip+'.part'
    if(Test-Path $temp){Remove-Item $temp -Force}
    $curl=Get-Command curl.exe -ErrorAction Stop
    $args=@('-L','--fail','--silent','--show-error','--retry','2','--connect-timeout','15','--max-time','220','--output',$temp,$url)
    $proc=Start-Process -FilePath $curl.Source -ArgumentList $args -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $logs 'download-stdout.log') -RedirectStandardError (Join-Path $logs 'download-stderr.log')
    if($proc.ExitCode -ne 0){throw ('Goose archive download failed, curl exit='+$proc.ExitCode)}
    Move-Item -LiteralPath $temp -Destination $zip -Force
    $report.downloaded=$true
  }
  $report.stage='checksum'
  $actual=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actual -ne $sha){throw ('Downloaded archive SHA256 mismatch: '+$actual)}
  $report.verified=$true
  $report.stage='install'
  $stageDir=Join-Path $root 'staging-v1.56.0'
  if(Test-Path $stageDir){Remove-Item -LiteralPath $stageDir -Recurse -Force}
  New-Item -ItemType Directory -Path $stageDir|Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $stageDir -Force
  $candidates=@(Get-ChildItem -LiteralPath $stageDir -Filter 'goose.exe' -File -Recurse)
  if($candidates.Count -ne 1){throw ('Expected exactly one goose.exe in archive; found '+$candidates.Count)}
  $payload=Split-Path -Parent $candidates[0].FullName
  Copy-Item -LiteralPath $candidates[0].FullName -Destination $exe -Force
  foreach($dll in @(Get-ChildItem -LiteralPath $payload -Filter '*.dll' -File)){Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $bin $dll.Name) -Force}
  Remove-Item -LiteralPath $stageDir -Recurse -Force
  $report.stage='version'
  $versionText=(& $exe --version 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0){throw ('goose.exe --version failed: '+$versionText)}
  $report.goose_version=$versionText
  $report.stage='launcher'
  $cmd=Join-Path $root 'Goose-Local-4B.cmd'
  $cmdContent=@(
    '@echo off',
    'set "GOOSE_PROVIDER=ollama"',
    'set "GOOSE_MODEL=qwen3.5:4b"',
    'set "OLLAMA_HOST=http://127.0.0.1:11434"',
    'set "GOOSE_DISABLE_KEYRING=1"',
    'set "GOOSE_MODE=approve"',
    'cd /d "D:\LocalAI\Goose\workspace"',
    '"D:\LocalAI\Goose\bin\goose.exe" session --with-builtin developer',
    'pause'
  )
  [IO.File]::WriteAllLines($cmd,$cmdContent,[Text.Encoding]::ASCII)
  $report.launcher=$cmd
  $report.status='success'
  $report.stage='done'
  $report.error='Goose CLI installed, checksum verified; local-only starter created.'
}
catch{
  $report.error=[string]$_.Exception.Message
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
if(Test-Path $logs){$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $logs 'installation-result.json') -Encoding UTF8}
exit 0
