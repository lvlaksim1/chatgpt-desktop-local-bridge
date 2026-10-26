[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$base='D:\LocalAI\Goose'
$download=Join-Path $base 'downloads\Goose-win32-x64-v1.56.0.zip'
$releaseDir=Join-Path $base 'desktop\v1.56.0'
$work=Join-Path $base 'workspace'
$logs=Join-Path $base 'logs'
$url='https://github.com/aaif-goose/goose/releases/download/v1.56.0/Goose-win32-x64.zip'
$expected='f724c5b9663b62287ccf2a7ee1c597efdf359f4e8068d0bb556b59c85044932b'
$report=[ordered]@{status='failed';error='';stage='start';version='1.56.0';download_verified=$false;downloaded=$false;executable='';executable_exists=$false;start_command='';shortcut='';russian_hints='';locale_setting='ru';telemetry_disabled_in_launcher=$false;ollama_reachable=$false;sha256=''}
try {
 foreach($dir in @((Split-Path -Parent $download),$releaseDir,$work,$logs)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
 try {
  $v=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -Method Get -TimeoutSec 5
  $report.ollama_reachable=$true
 }catch{throw ('Local Ollama is not responding: '+$_.Exception.Message)}
 $report.stage='download'
 $valid=$false
 if(Test-Path -LiteralPath $download -PathType Leaf){
  $hash=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
  $valid=($hash -eq $expected)
 }
 if(-not $valid){
  $partial=$download+'.part'
  if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
  $curl=Get-Command curl.exe -ErrorAction Stop
  $curlArgs=@('-L','--fail','--silent','--show-error','--retry','2','--connect-timeout','25','--max-time','600','--output',$partial,$url)
  $proc=Start-Process -FilePath $curl.Source -ArgumentList $curlArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $logs 'goose-desktop-download.stdout.log') -RedirectStandardError (Join-Path $logs 'goose-desktop-download.stderr.log')
  $proc.Refresh()
  if($proc.ExitCode -ne 0){throw ('Goose Desktop download failed. curl exit '+$proc.ExitCode)}
  $hash=(Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
  if($hash -ne $expected){Remove-Item $partial -Force;throw ('Archive SHA256 mismatch: '+$hash)}
  Move-Item -LiteralPath $partial -Destination $download -Force
  $report.downloaded=$true
 }
 $report.sha256=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
 if($report.sha256 -ne $expected){throw 'Release archive hash mismatch'}
 $report.download_verified=$true
 $report.stage='extract'
 $appExe=@(Get-ChildItem -LiteralPath $releaseDir -Recurse -File -Filter 'Goose.exe' -ErrorAction SilentlyContinue|Select-Object -First 2)
 if($appExe.Count -ne 1){
  $staging=Join-Path $base 'desktop\.stage-v1.56.0'
  if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}
  Expand-Archive -LiteralPath $download -DestinationPath $staging -Force
  $sourceExe=@(Get-ChildItem -LiteralPath $staging -Recurse -File -Filter 'Goose.exe')
  if($sourceExe.Count -ne 1){throw ('Expected exactly one desktop Goose.exe, found '+$sourceExe.Count)}
  $sourceDir=Split-Path -Parent $sourceExe[0].FullName
  Copy-Item -Path (Join-Path $sourceDir '*') -Destination $releaseDir -Recurse -Force
  Remove-Item -LiteralPath $staging -Recurse -Force
  $appExe=@(Get-ChildItem -LiteralPath $releaseDir -File -Filter 'Goose.exe')
 }
 if($appExe.Count -ne 1){throw 'Goose Desktop executable missing after extraction'}
 $actualExe=$appExe[0].FullName
 $report.executable=$actualExe
 $report.executable_exists=Test-Path -LiteralPath $actualExe -PathType Leaf
 if(-not $report.executable_exists){throw 'Goose Desktop exe not found'}
 $report.stage='launcher'
 $launch=Join-Path $base 'Goose-RU.cmd'
 $lines=@(
  '@echo off',
  'chcp 65001 >nul',
  'setlocal',
  'set "HTTP_PROXY="',
  'set "HTTPS_PROXY="',
  'set "ALL_PROXY="',
  'set "http_proxy="',
  'set "https_proxy="',
  'set "all_proxy="',
  'set "NO_PROXY=localhost,127.0.0.1,::1"',
  'set "GOOSE_LOCALE=ru"',
  'set "GOOSE_TELEMETRY_ENABLED=false"',
  'set "GOOSE_PATH_ROOT=D:\LocalAI\Goose\profile"',
  'set "GOOSE_PROVIDER=ollama"',
  'set "GOOSE_MODEL=qwen3.5:4b-goose"',
  'set "GOOSE_MODE=approve"',
  'set "OLLAMA_HOST=http://127.0.0.1:11434"',
  'set "OLLAMA_NO_CLOUD=1"',
  'set "GOOSE_INPUT_LIMIT=8192"',
  'set "OLLAMA_STREAM_USAGE=false"',
  'cd /d "D:\LocalAI\Goose\workspace"',
  'start "" "'+$actualExe+'"'
 )
 [IO.File]::WriteAllLines($launch,$lines,[Text.Encoding]::ASCII)
 $report.start_command=$launch
 $report.telemetry_disabled_in_launcher=$true
 $hintsPath=Join-Path $work '.goosehints'
 if(-not (Test-Path -LiteralPath $hintsPath -PathType Leaf)){
  $hints=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0J7RgtCy0LXRh9Cw0Lkg0L3QsCDRgNGD0YHRgdC60L7QvCDRj9C30YvQutC1LiDQktGB0LUg0L/QvtGP0YHQvdC10L3QuNGPLCDQv9C70LDQvdGLLCDRg9GC0L7Rh9C90Y/RjtGJ0LjQtSDQstC+0L/RgNC+0YHRiyDQuCDQvtGC0YfRkdGC0Ysg0L7QsSDQvtC/0LXRgNCw0YbQuNGP0YUg0L/QuNGI0Lgg0L/Qvi3RgNGD0YHRgdC60LguINCd0LUg0L/QtdGA0LXQstC+0LTQuCDQuNC80LXQvdCwINGE0LDQudC70L7Qsiwg0LrQvtC80LDQvdC00YssINC40LzQtdC90LAg0L/QtdGA0LXQvNC10L3QvdGL0YUg0Lgg0YLQtdGF0L3QuNGH0LXRgdC60LjQtSDQuNC00LXQvdGC0LjRhNC40LrQsNGC0L7RgNGLLiDQn9C10YDQtdC0INC40LfQvNC10L3QtdC90LjQtdC8INGE0LDQudC70L7QsiDQuNC70Lgg0LfQsNC/0YPRgdC60L7QvCDQv9C+0YLQtdC90YbQuNCw0LvRjNC90L4g0L7Qv9Cw0YHQvdC+0Lkg0LrQvtC80LDQvdC00Ysg0LfQsNC/0YDQsNGI0LjQstCw0Lkg0L/QvtC00YLQstC10YDQttC00LXQvdC40LUu')))
  [IO.File]::WriteAllText($hintsPath,$hints,(New-Object System.Text.UTF8Encoding($false)))
 }
 $report.russian_hints=$hintsPath
 $desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
 if(-not [string]::IsNullOrWhiteSpace($desktop)){
  $shortcut=Join-Path $desktop ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2UgLSDQoNGD0YHRgdC60LjQuS5sbms=')))
  $shell=New-Object -ComObject WScript.Shell
  $link=$shell.CreateShortcut($shortcut)
  $link.TargetPath=Join-Path $env:SystemRoot 'System32\cmd.exe'
  $link.Arguments='/c ""'+$launch+'""'
  $link.WorkingDirectory=$base
  $link.IconLocation=$actualExe+',0'
  $link.Description=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('R29vc2U6INGA0YPRgdGB0LrQuNC5INCz0YDQsNGE0LjRh9C10YHQutC40Lkg0LjQvdGC0LXRgNGE0LXQudGBLCDQu9C+0LrQsNC70YzQvdCw0Y8g0LzQvtC00LXQu9GMIFF3ZW4zLjU=')))
  $link.Save()
  $report.shortcut=$shortcut
 }
 $report.stage='done'
 $report.status='success'
 $report.error='Russian-localized desktop release verified, installed on D, Russian desktop shortcut created; GUI first-run visual check not yet performed.'
}catch{$report.error=[string]$_.Exception.Message}
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
if(Test-Path -LiteralPath $logs -PathType Container){$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $logs 'desktop-russian-install-result.json') -Encoding UTF8}
exit 0
