[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Result {
    param([hashtable]$Payload,[int]$ExitCode=0)
    $dir=Split-Path -Parent $GatewayResultPath
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $Payload|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($Payload|ConvertTo-Json -Depth 16 -Compress))
    exit $ExitCode
}

$installRoot=Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$releaseInfoPath=Join-Path $installRoot 'release-info.json'
$logRoot=Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\logs'

$release=$null
if(Test-Path -LiteralPath $releaseInfoPath -PathType Leaf){
    try{$release=Get-Content -LiteralPath $releaseInfoPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
}

$apps=@()
$uiTexts=@()
try{
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}catch{}

foreach($p in @(Get-Process -Name 'ChatGptDesktopLocalBridge' -ErrorAction SilentlyContinue)){
    $apps += @{
        pid=$p.Id
        session_id=$p.SessionId
        title=$p.MainWindowTitle
        main_window_handle=[int64]$p.MainWindowHandle
    }
    if($p.MainWindowHandle -ne 0){
        try{
            $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$p.MainWindowHandle)
            if($null -ne $root){
                $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
                foreach($el in $all){
                    try{
                        if($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text){
                            $n=[string]$el.Current.Name
                            if(-not [string]::IsNullOrWhiteSpace($n)){$uiTexts += $n}
                        }
                    }catch{}
                }
            }
        }catch{}
    }
}
$uiTexts=@($uiTexts|Select-Object -Unique)

$webviews=@()
$ports=@()
foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
  Where-Object{[string]$_.CommandLine -like '*ChatGptDesktopLocalBridge\WebView2*'})){
    $cmd=[string]$p.CommandLine
    $port=$null
    if($cmd -match '--remote-debugging-port=(\d+)'){$port=[int]$Matches[1];$ports += $port}
    $webviews += @{pid=[int]$p.ProcessId;port=$port;command_line=$cmd}
}

$targets=@()
foreach($port in @($ports|Select-Object -Unique)){
    try{
        $items=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+ $port +'/json') -UseBasicParsing -TimeoutSec 2)
        foreach($t in $items){
            $targets += @{port=$port;type=[string]$t.type;url=[string]$t.url;title=[string]$t.title}
        }
    }catch{
        $targets += @{port=$port;type='error';url='';title=$_.Exception.Message}
    }
}

$logTail=@()
if(Test-Path -LiteralPath $logRoot -PathType Container){
    foreach($f in @(Get-ChildItem -LiteralPath $logRoot -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 2)){
        $logTail += @{file=$f.Name;tail=@(Get-Content -LiteralPath $f.FullName -Tail 20 -ErrorAction SilentlyContinue)}
    }
}

Write-Result @{
    status='diagnostic'
    release_tag=if($null-ne$release){[string]$release.tag}else{$null}
    release_commit=if($null-ne$release){[string]$release.commit}else{$null}
    processes=$apps
    ui_texts=$uiTexts
    webviews=$webviews
    targets=$targets
    log_tail=$logTail
}