[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$targetTag = 'dev-f4a3433'
$targetCommit = 'f4a3433fbb5ba7a60abb22c3b298db799fd16b66'
$assetName = 'ChatGptDesktopLocalBridge-Update-from-dev-450b884.exe'
$expectedSha256 = '22796e11d381456dab29453a92937ac11a7b2fe5d139ccde1ac7e22ae467edcf'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$appExe = Join-Path $installRoot 'ChatGptDesktopLocalBridge.exe'
$releaseInfo = Join-Path $installRoot 'release-info.json'
$tempRoot = Join-Path $env:TEMP ('bridge-update-' + [Guid]::NewGuid().ToString('N'))
$updateExe = Join-Path $tempRoot $assetName
$updateLog = Join-Path $tempRoot 'inno-update.log'
$oldSkip = [Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','Process')

function Write-Result {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;target_tag=$targetTag;target_commit=$targetCommit}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Get-Sha256([string]$Path){
    $stream=[IO.File]::OpenRead($Path)
    try{
        $sha=[Security.Cryptography.SHA256]::Create()
        try{
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
        }finally{$sha.Dispose()}
    }finally{$stream.Dispose()}
}

function Stop-App {
    foreach($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
    }
}

try{
    if(-not(Test-Path -LiteralPath $appExe -PathType Leaf)){throw 'Installed application executable is missing.'}

    $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D6B9AF8-6D08-44E1-B2F5-8A6341D99165}_is1'
    if(-not(Test-Path -LiteralPath $uninstallKey)){throw 'Windows installer registration is missing.'}
    $displayVersion=[string](Get-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -ErrorAction Stop).DisplayVersion

    if(Test-Path -LiteralPath $releaseInfo -PathType Leaf){
        $existing=Get-Content -LiteralPath $releaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
        if([string]$existing.tag -eq $targetTag -and [string]$existing.commit -eq $targetCommit){
            Write-Result -Status 'success' -ExitCode 0 -Extra @{already_current=$true;display_version=$displayVersion}
        }
        throw "Unexpected marker-based installed release '$($existing.tag)'."
    }

    if($displayVersion -ne '0.1.28.0'){
        throw "Legacy base mismatch: installed version '$displayVersion', expected '0.1.28.0' (dev-450b884)."
    }

    New-Item -ItemType Directory -Force -Path $tempRoot|Out-Null
    $url='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/'+$targetTag+'/'+$assetName
    $wc=New-Object Net.WebClient
    try{$wc.DownloadFile($url,$updateExe)}finally{$wc.Dispose()}

    $actual=Get-Sha256 $updateExe
    if($actual -ne $expectedSha256){throw "Updater hash mismatch: $actual"}

    Stop-App
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')

    $p=Start-Process -FilePath $updateExe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$updateLog)) -PassThru
    if(-not $p.WaitForExit(180000)){
        try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
        throw 'Updater timed out after 180 seconds.'
    }
    $p.Refresh()
    if($p.ExitCode -ne 0){
        $details=''
        if(Test-Path -LiteralPath $updateLog){$details=@(Get-Content -LiteralPath $updateLog -Tail 80)-join [Environment]::NewLine}
        throw "Updater failed with exit code $($p.ExitCode). $details"
    }

    if(-not(Test-Path -LiteralPath $releaseInfo -PathType Leaf)){throw 'Update succeeded but release-info.json is missing.'}
    $info=Get-Content -LiteralPath $releaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$info.tag -ne $targetTag -or [string]$info.commit -ne $targetCommit){
        throw "Target release marker mismatch: '$($info.tag)' '$($info.commit)'."
    }

    $newDisplay=[string](Get-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -ErrorAction Stop).DisplayVersion
    Write-Result -Status 'success' -ExitCode 0 -Extra @{already_current=$false;display_version_before=$displayVersion;display_version_after=$newDisplay}
}
catch{
    Write-Result -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message
}
finally{
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',$oldSkip,'Process')
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
