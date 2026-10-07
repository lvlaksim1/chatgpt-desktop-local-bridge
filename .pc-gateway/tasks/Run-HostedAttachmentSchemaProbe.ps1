[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
    [Parameter(Mandatory=$true)][string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$HostedRunId='37630628088'
$HostedRepo='lvlaksim1/chatgpt-desktop-local-bridge'
$ArtifactName='attachment-research-publish'
$NetworkGapSeconds=5

function Write-Result {
    param([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{})
    $o=[ordered]@{status=$Status;exit_code=$Code;error=$ErrorText;network_min_gap_seconds=$NetworkGapSeconds}
    foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $o|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $Code
}

function Stop-BridgeProcesses {
    Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Invoke-BoundedProcess {
    param([string]$FilePath,[string]$Arguments,[string]$WorkingDirectory,[int]$TimeoutMs)

    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$FilePath
    $psi.Arguments=$Arguments
    $psi.WorkingDirectory=$WorkingDirectory
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true

    $p=New-Object Diagnostics.Process
    $p.StartInfo=$psi
    if(-not $p.Start()){throw 'process_start_failed'}

    if(-not $p.WaitForExit($TimeoutMs)){
        try{$p.Kill()}catch{}
        throw 'process_timeout'
    }

    $stdout=$p.StandardOutput.ReadToEnd()
    $stderr=$p.StandardError.ReadToEnd()
    return [ordered]@{exit_code=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
}

$request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$requestId=[string]$request.request_id
if([string]::IsNullOrWhiteSpace($requestId)){$requestId='attachment-hosted'}

$installed=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge\ChatGptDesktopLocalBridge.exe'
$root=Join-Path $env:LOCALAPPDATA ('GitHubRunner\attachment-hosted\'+$requestId)
$artifactDir=Join-Path $root 'artifact'
$probeResult=Join-Path $root 'probe-result.json'
$researchExe=Join-Path $artifactDir 'ChatGptDesktopLocalBridge.exe'

try{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $artifactDir|Out-Null

    $gh=(Get-Command gh.exe -ErrorAction SilentlyContinue)
    if($null -eq $gh){throw 'gh_not_found'}

    $args='run download '+$HostedRunId+' --repo '+$HostedRepo+' --name '+$ArtifactName+' --dir "'+$artifactDir+'"'
    $download=Invoke-BoundedProcess -FilePath ([string]$gh.Source) -Arguments $args -WorkingDirectory $root -TimeoutMs 120000

    if([int]$download.exit_code -ne 0){throw ('artifact_download_failed:'+[string]$download.stderr)}

    Start-Sleep -Seconds $NetworkGapSeconds

    if(-not(Test-Path -LiteralPath $researchExe -PathType Leaf)){throw 'research_exe_missing'}

    Stop-BridgeProcesses

    $oldResultEnv=[Environment]::GetEnvironmentVariable('LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT','Process')
    [Environment]::SetEnvironmentVariable('LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT',$probeResult,'Process')

    $probeProcess=Start-Process -FilePath $researchExe -PassThru

    $deadline=[DateTime]::UtcNow.AddSeconds(100)
    while([DateTime]::UtcNow -lt $deadline){
        if(Test-Path -LiteralPath $probeResult -PathType Leaf){break}
        if($probeProcess.HasExited){break}
        Start-Sleep -Milliseconds 500
    }

    [Environment]::SetEnvironmentVariable('LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT',$oldResultEnv,'Process')

    if(-not(Test-Path -LiteralPath $probeResult -PathType Leaf)){
        try{if(-not $probeProcess.HasExited){$probeProcess|Stop-Process -Force}}catch{}
        throw 'probe_result_missing'
    }

    $probeRaw=Get-Content -LiteralPath $probeResult -Raw -Encoding UTF8
    $probe=$probeRaw|ConvertFrom-Json

    Stop-BridgeProcesses
    if(Test-Path -LiteralPath $installed -PathType Leaf){Start-Process -FilePath $installed|Out-Null}

    Write-Result -Status 'evidence' -Code 7 -ErrorText ($probe|ConvertTo-Json -Depth 25 -Compress) -Extra @{hosted_run_id=$HostedRunId;artifact_name=$ArtifactName;normal_app_restarted=(Test-Path -LiteralPath $installed -PathType Leaf)}
}
catch{
    try{
        [Environment]::SetEnvironmentVariable('LOCAL_BRIDGE_ATTACHMENT_RESEARCH_RESULT',$null,'Process')
        Stop-BridgeProcesses
        if(Test-Path -LiteralPath $installed -PathType Leaf){Start-Process -FilePath $installed|Out-Null}
    }catch{}
    Write-Result -Status 'fail' -Code 40 -ErrorText $_.Exception.Message
}
