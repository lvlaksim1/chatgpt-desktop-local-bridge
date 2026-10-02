[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$baseTag='dev-f4a3433'
$baseCommit='f4a3433fbb5ba7a60abb22c3b298db799fd16b66'
$targetTag='dev-72b6766'
$targetCommit='72b676608d8e9ebb949af451b4dda7fd8a6061c8'
$assetName='ChatGptDesktopLocalBridge-Update-from-dev-f4a3433.exe'
$expectedSha256='88e223fbe319de811704de31c545ecc8e32fed6e250d86e4c8ee6f38af3c6231'

$installRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$appExe=Join-Path $installRoot 'ChatGptDesktopLocalBridge.exe'
$releaseInfo=Join-Path $installRoot 'release-info.json'
$tempRoot=Join-Path $env:TEMP ('bridge-update-'+[Guid]::NewGuid().ToString('N'))
$updateExe=Join-Path $tempRoot $assetName
$updateLog=Join-Path $tempRoot 'inno-update.log'
$oldSkip=[Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','Process')

function Write-Result([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;base_tag=$baseTag;target_tag=$targetTag;target_commit=$targetCommit}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Depth 12 -Compress))
    exit $ExitCode
}

function Sha256([string]$Path){
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Stop-App {
    foreach($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
    }
}

try{
    if(-not(Test-Path -LiteralPath $appExe -PathType Leaf)){throw 'Installed application executable is missing.'}
    if(-not(Test-Path -LiteralPath $releaseInfo -PathType Leaf)){throw 'Installed release marker is missing.'}

    $before=Get-Content -LiteralPath $releaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$before.tag -eq $targetTag -and [string]$before.commit -eq $targetCommit){
        Write-Result 'success' 0 '' @{already_current=$true}
    }
    if([string]$before.tag -ne $baseTag -or [string]$before.commit -ne $baseCommit){
        throw "Installed base mismatch: '$($before.tag)' '$($before.commit)'."
    }

    New-Item -ItemType Directory -Force -Path $tempRoot|Out-Null
    $url='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/'+$targetTag+'/'+$assetName
    $wc=New-Object Net.WebClient
    try{$wc.DownloadFile($url,$updateExe)}finally{$wc.Dispose()}

    $actual=Sha256 $updateExe
    if($actual -ne $expectedSha256){throw "Updater hash mismatch: $actual"}

    Stop-App
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')

    $p=Start-Process -FilePath $updateExe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$updateLog)) -PassThru
    if(-not $p.WaitForExit(120000)){
        try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
        throw 'Updater timed out after 120 seconds.'
    }
    $p.Refresh()
    if($p.ExitCode -ne 0){
        $tail=''
        if(Test-Path -LiteralPath $updateLog){$tail=@(Get-Content -LiteralPath $updateLog -Tail 80)-join [Environment]::NewLine}
        throw "Updater failed with exit code $($p.ExitCode). $tail"
    }

    $after=Get-Content -LiteralPath $releaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$after.tag -ne $targetTag -or [string]$after.commit -ne $targetCommit){
        throw "Target marker mismatch: '$($after.tag)' '$($after.commit)'."
    }

    Write-Result 'success' 0 '' @{already_current=$false;installed_before=[string]$before.tag;installed_after=[string]$after.tag}
}catch{
    Write-Result 'fail' 31 $_.Exception.Message
}finally{
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',$oldSkip,'Process')
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}