[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$TargetTag = 'dev-f4a3433'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$ProcessName = 'ChatGptDesktopLocalBridge'

function Write-Result {
    param([string]$Status,[int]$ExitCode,[string]$ErrorText='',[hashtable]$Extra=@{})
    $payload=[ordered]@{status=$Status;error=$ErrorText;exit_code=$ExitCode;target_tag=$TargetTag}
    foreach($k in $Extra.Keys){$payload[$k]=$Extra[$k]}
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $payload|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

function Stop-App {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}catch{}
    }
    Start-Sleep -Seconds 2
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)){
        try{Stop-Process -Id $p.Id -Force -ErrorAction Stop}catch{}
    }
    $needle='ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object{[string]$_.CommandLine -like ('*'+$needle+'*')})){
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop}catch{}
    }
    Start-Sleep -Seconds 1
}

function Wait-App([int]$TimeoutSeconds=30){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $p=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1)
        if($p.Count -gt 0){return $p[0]}
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Invoke-Button($Root,[string]$Name){
    $cond=New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,$Name)
    $button=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
    if($null -eq $button){throw "UI button '$Name' not found."}
    $pattern=$null
    if(-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
        throw "UI button '$Name' not invokable."
    }
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Get-UiTexts($Root){
    $values=New-Object System.Collections.ArrayList
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all){
        try{
            if($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text){
                $n=[string]$el.Current.Name
                if(-not [string]::IsNullOrWhiteSpace($n)){[void]$values.Add($n)}
            }
        }catch{}
    }
    return @($values|Select-Object -Unique)
}

function Get-Diagnostics($Root){
    Invoke-Button $Root 'Diagnostics'
    Start-Sleep -Milliseconds 700
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $cond=New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,'Local Bridge diagnostics')
    $dialog=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
    if($null -eq $dialog){return 'diagnostics-dialog-not-found'}
    $parts=New-Object System.Collections.ArrayList
    $all=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all){
        try{
            $n=[string]$el.Current.Name
            if(-not [string]::IsNullOrWhiteSpace($n)){[void]$parts.Add($n)}
        }catch{}
    }
    try{
        $okCond=New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,'OK')
        $ok=$dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$okCond)
        if($null -ne $ok){
            $pat=$null
            if($ok.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pat)){
                ([System.Windows.Automation.InvokePattern]$pat).Invoke()
            }
        }
    }catch{}
    return (@($parts|Select-Object -Unique)-join ' || ')
}

$wasRunning=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$finalStatus=''
$lastDiagnostics=''
try{
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw 'Installed application executable is missing.'}
    if(-not(Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)){throw 'release-info.json is missing.'}
    $release=Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$release.tag -ne $TargetTag){throw "Installed release is '$($release.tag)', expected '$TargetTag'."}

    Stop-App
    Start-Process -FilePath $AppExe|Out-Null
    $p=Wait-App 30
    if($null -eq $p){throw 'Application window did not appear within 30 seconds.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$p.MainWindowHandle)
    if($null -eq $root){throw 'UI Automation root is unavailable.'}

    $ready=$false
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    while([DateTime]::UtcNow -lt $deadline){
        $lastDiagnostics=Get-Diagnostics $root
        if($lastDiagnostics -match '"version"\s*:\s*3' -and
           $lastDiagnostics -match '"composerFound"\s*:\s*true' -and
           $lastDiagnostics -match '"nativeInputReady"\s*:\s*true'){
            $ready=$true
            break
        }
        Start-Sleep -Seconds 2
    }
    if(-not $ready){throw ('Adapter/composer not ready within 35 seconds. Last diagnostics: '+$lastDiagnostics)}

    Invoke-Button $root 'Initialize Bridge'

    $deadline=[DateTime]::UtcNow.AddSeconds(70)
    while([DateTime]::UtcNow -lt $deadline){
        $texts=@(Get-UiTexts $root)
        $success=@($texts|Where-Object{$_ -like 'Bridge ready. Session*'}|Select-Object -First 1)
        if($success.Count -gt 0){
            $finalStatus=[string]$success[0]
            Write-Result -Status 'pass' -ExitCode 0 -Extra @{bridge_status=$finalStatus;diagnostics=$lastDiagnostics}
        }
        $failure=@($texts|Where-Object{
            $_ -like 'Could not send bridge bootstrap*' -or
            $_ -like 'Bridge bootstrap was sent, but ChatGPT did not return*' -or
            $_ -like 'Bridge initialization failed:*' -or
            $_ -like 'Chat send failed:*' -or
            $_ -like 'Bridge error:*'
        }|Select-Object -First 1)
        if($failure.Count -gt 0){
            $finalStatus=[string]$failure[0]
            throw $finalStatus
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Timed out after 70 seconds waiting for Bridge ready.'
}
catch{
    Write-Result -Status 'fail' -ExitCode 31 -ErrorText $_.Exception.Message -Extra @{
        bridge_status=$finalStatus
        diagnostics=$lastDiagnostics
    }
}
finally{
    try{Stop-App}catch{}
    try{
        if($wasRunning -and (Test-Path -LiteralPath $AppExe -PathType Leaf)){
            Start-Process -FilePath $AppExe|Out-Null
        }
    }catch{}
}
