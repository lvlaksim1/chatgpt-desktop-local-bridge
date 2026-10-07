[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$PackageCommit='314e43510b0790ecc54493a7e4fa83e7e72f5044'
$PackageTag='local-intent-worker-test-314e435'
$ZipName='ChatGptDesktopLocalBridge-Feature.zip'
$HashName='ChatGptDesktopLocalBridge-Feature.zip.sha256'
$RepoUrl='https://github.com/lvlaksim1/chatgpt-desktop-local-bridge'
$Temp=Join-Path $env:TEMP ('lb-worker-prebuilt-'+[Guid]::NewGuid().ToString('N'))
$Zip=Join-Path $Temp $ZipName
$HashFile=Join-Path $Temp $HashName
$Payload=Join-Path $Temp 'payload'
$PatchedProbe=Join-Path $Temp 'Probe-DedicatedLocalIntentWorkerV2-prebuilt.ps1'
$SourceProbe=Join-Path $PSScriptRoot 'Probe-DedicatedLocalIntentWorkerV2.ps1'

try{
    New-Item -ItemType Directory -Force -Path $Temp,$Payload|Out-Null

    $wc=New-Object Net.WebClient
    try{
        $wc.DownloadFile("$RepoUrl/releases/download/$PackageTag/$ZipName",$Zip)
        Start-Sleep -Seconds 5
        $wc.DownloadFile("$RepoUrl/releases/download/$PackageTag/$HashName",$HashFile)
    }finally{$wc.Dispose()}

    $expected=((Get-Content -LiteralPath $HashFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual=(Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if([string]::IsNullOrWhiteSpace($expected) -or $actual -ne $expected){
        throw "Package SHA256 mismatch: expected=$expected actual=$actual"
    }

    Expand-Archive -LiteralPath $Zip -DestinationPath $Payload -Force
    $releaseInfo=Join-Path $Payload 'release-info.json'
    if(-not(Test-Path -LiteralPath $releaseInfo -PathType Leaf)){throw 'release-info.json missing from package.'}
    $release=Get-Content -LiteralPath $releaseInfo -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$release.commit -ne $PackageCommit){throw "Package commit mismatch: $($release.commit)"}

    if(-not(Test-Path -LiteralPath $SourceProbe -PathType Leaf)){throw 'V2 probe script missing.'}
    $text=Get-Content -LiteralPath $SourceProbe -Raw -Encoding UTF8

    $oldBuild=@'
    & dotnet.exe publish $Project --configuration Release --runtime win-x64 --self-contained true --output $Publish
    if($LASTEXITCODE -ne 0){throw "Publish failed: $LASTEXITCODE"}
    $FeatureExe=Join-Path $Publish 'ChatGptDesktopLocalBridge.exe'
    if(-not(Test-Path $FeatureExe)){throw 'Feature executable missing.'}
'@

    $newBuild=@'
    New-Item -ItemType Directory -Force -Path $Publish|Out-Null
    Copy-Item -Path (Join-Path $env:LB_PREBUILT_PAYLOAD '*') -Destination $Publish -Recurse -Force
    $FeatureExe=Join-Path $Publish 'ChatGptDesktopLocalBridge.exe'
    if(-not(Test-Path $FeatureExe)){throw 'Prebuilt feature executable missing.'}
'@

    if(-not$text.Contains($oldBuild)){throw 'V2 build block was not found for prebuilt patching.'}
    $text=$text.Replace($oldBuild,$newBuild)

    $oldExit='    exit $Code'
    $newExit='    $script:RequestedExitCode=$Code; return'
    if(-not$text.Contains($oldExit)){throw 'V2 result exit line was not found for wrapper patching.'}
    $text=$text.Replace($oldExit,$newExit)

    Set-Content -LiteralPath $PatchedProbe -Value $text -Encoding UTF8
    $env:LB_PREBUILT_PAYLOAD=$Payload
    try{
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PatchedProbe -GatewayRequestPath $GatewayRequestPath -GatewayResultPath $GatewayResultPath
        $childExit=$LASTEXITCODE
    }finally{
        Remove-Item Env:\LB_PREBUILT_PAYLOAD -ErrorAction SilentlyContinue
    }

    if(Test-Path -LiteralPath $GatewayResultPath -PathType Leaf){
        $result=Get-Content -LiteralPath $GatewayResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        exit [int]$result.exit_code
    }

    exit $childExit
}
catch{
    $payload=[ordered]@{
        status='fail'
        error=$_.Exception.Message
        exit_code=31
        stage='prebuilt-wrapper'
        package_tag=$PackageTag
        package_commit=$PackageCommit
    }
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON='+($payload|ConvertTo-Json -Compress))
    exit 31
}
finally{
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
