[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

function Write-Result([string]$Status,[int]$Code,[string]$ErrorText,[hashtable]$Extra){
    $o=[ordered]@{status=$Status;exit_code=$Code;error=$ErrorText}
    foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $o|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $Code
}

$req=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$requestId=[string]$req.request_id
if([string]::IsNullOrWhiteSpace($requestId)){$requestId='attachment-inproc'}

$installed=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$root=Join-Path $env:LOCALAPPDATA ('GitHubRunner\attachment-inproc\'+$requestId)
$publish=Join-Path $root 'publish'
$probeResult=Join-Path $root 'probe-result.json'
$project=Join-Path (Get-Location) 'src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj'

try{
    if(-not(Test-Path -LiteralPath $project -PathType Leaf)){throw 'project_missing'}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $publish|Out-Null

    $publishOutput=& dotnet publish $project -c Release -r win-x64 --self-contained false -o $publish --disable-build-servers 2>&1
    if($LASTEXITCODE -ne 0){
        throw ('publish_failed:' + (($publishOutput|Out-String).Trim()))
    }

    $exe=Join-Path $publish 'ChatGptDesktopLocalBridge.exe'
    if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'research_exe_missing'}

    Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $env:LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT=$probeResult
    $p=Start-Process -FilePath $exe -PassThru

    $deadline=[DateTime]::UtcNow.AddMinutes(2)
    while([DateTime]::UtcNow -lt $deadline){
        if(Test-Path -LiteralPath $probeResult -PathType Leaf){break}
        if($p.HasExited -and -not(Test-Path -LiteralPath $probeResult)){break}
        Start-Sleep -Seconds 1
    }

    $env:LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT=$null

    if(-not(Test-Path -LiteralPath $probeResult -PathType Leaf)){
        try{if(-not $p.HasExited){$p|Stop-Process -Force}}catch{}
        throw 'probe_result_missing'
    }

    $probe=Get-Content -LiteralPath $probeResult -Raw -Encoding UTF8
    $probeObj=$probe|ConvertFrom-Json

    if(Test-Path -LiteralPath $installed -PathType Leaf){
        Start-Process -FilePath $installed|Out-Null
    }

    Write-Result 'evidence' 7 ($probeObj|ConvertTo-Json -Depth 25 -Compress) @{
        research_build='pass'
        normal_app_restarted=(Test-Path -LiteralPath $installed -PathType Leaf)
    }
}
catch{
    $env:LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT=$null
    try{
        Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue|
            Stop-Process -Force -ErrorAction SilentlyContinue
        if(Test-Path -LiteralPath $installed -PathType Leaf){
            Start-Process -FilePath $installed|Out-Null
        }
    }catch{}
    Write-Result 'fail' 40 $_.Exception.Message @{}
}
