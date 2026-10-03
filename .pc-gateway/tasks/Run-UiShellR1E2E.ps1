[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$TargetTag = 'ui-shell-4c92f81'
$TargetCommit = '4c92f81d46b77f964b8e99fe25439058b9b835a1'
$BaseTag = 'ui-shell-af6ac65'
$BaseCommit = 'af6ac65306d5e91b84c48bb44fb7bc37da930053'
$DeltaName = 'ChatGptDesktopLocalBridge-Update-from-ui-shell-af6ac65.exe'
$DeltaSha256 = 'a7dafb406b6af3bc45c04f5ff889518fd52b97ba8bb229ae6f6a3f96cffbb618'
$BaseSetupName = 'ChatGptDesktopLocalBridge-ui-shell-Setup.exe'
$BaseSetupSha256 = '6b38de7189184506a0ede06c32ac6ffadceb07fe90f7e3d38ad35f5cfc9e4cc1'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT Desktop Local Bridge'
$AppExe = Join-Path $InstallRoot 'ChatGptDesktopLocalBridge.exe'
$ReleaseInfoPath = Join-Path $InstallRoot 'release-info.json'
$SettingsPath = Join-Path $env:LOCALAPPDATA 'ChatGptDesktopLocalBridge\settings.json'
$TempRoot = Join-Path $env:TEMP ('ui-shell-r1-e2e-' + [Guid]::NewGuid().ToString('N'))
$DeltaPath = Join-Path $TempRoot $DeltaName
$BaseSetupPath = Join-Path $TempRoot ('rollback-' + $BaseSetupName)
$DownloadRoot = Join-Path $TempRoot 'downloads'
$UpdateLog = Join-Path $TempRoot 'delta-update.log'
$RollbackLog = Join-Path $TempRoot 'rollback-setup.log'
$SettingsBackup = Join-Path $TempRoot 'settings.backup.json'
$ProcessName = 'ChatGptDesktopLocalBridge'
$TestStarted = [DateTimeOffset]::UtcNow
$OldBrowserArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
$OldSkipRestart = [Environment]::GetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART', 'Process')

function Decode-Utf8Base64([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

$UiBridgeReadyPattern = Decode-Utf8Base64 '0JzQvtGB0YIg0LPQvtGC0L7QsiDCtyo='
$UiBridgeButton = Decode-Utf8Base64 '0JzQvtGB0YI='
$UiNewChat = Decode-Utf8Base64 'KyDQp9Cw0YI='
$UiSettings = Decode-Utf8Base64 '0J3QsNGB0YLRgNC+0LnQutC4'
$UiOpenInNewTab = Decode-Utf8Base64 '0J7RgtC60YDRi9GC0Ywg0LIg0L3QvtCy0L7QuSDQstC60LvQsNC00LrQtQ=='
$UiResetTheme = Decode-Utf8Base64 '0KHQsdGA0L7RgdC40YLRjCDRgtC10LzRgw=='
$UiFullSetup = Decode-Utf8Base64 '0KHQutCw0YfQsNGC0Ywg0Lgg0LfQsNC/0YPRgdGC0LjRgtGMINC/0L7Qu9C90YvQuSBTZXR1cA=='
$UiFullSetupShort = Decode-Utf8Base64 '0J/QvtC70L3Ri9C5IFNldHVw'
$UiSave = Decode-Utf8Base64 '0KHQvtGF0YDQsNC90LjRgtGM'
$Socket = $null
$RollbackNeeded = $false
$SettingsHadFile = $false
$AppWasRunning = $false
$Result = [ordered]@{
    status = 'running'
    target_tag = $TargetTag
    target_commit = $TargetCommit
    base_tag = $BaseTag
    test_started_utc = $TestStarted.ToString('o')
    checks = [ordered]@{}
}

function Set-Check {
    param([string]$Name, [bool]$Pass, $Details = $null)
    $Result.checks[$Name] = [ordered]@{ pass = $Pass; details = $Details }
    Write-Host ('UI_R1_CHECK=' + $Name + ':' + $(if($Pass){'PASS'}else{'FAIL'}))
}

function Write-ProjectResult {
    param([string]$Status, [int]$ExitCode, [string]$ErrorText = '')
    $Result.status = $Status
    $Result.exit_code = $ExitCode
    $Result.error = $ErrorText
    $Result.test_finished_utc = [DateTimeOffset]::UtcNow.ToString('o')
    $dir = Split-Path -Parent $GatewayResultPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    Write-Host ('PC_GATEWAY_PROJECT_RESULT_JSON=' + ($Result | ConvertTo-Json -Depth 30 -Compress))
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-Verified([string]$Url, [string]$Path, [string]$ExpectedHash) {
    $wc = New-Object Net.WebClient
    try { $wc.DownloadFile($Url, $Path) } finally { $wc.Dispose() }
    $actual = Get-Sha256 $Path
    if ($actual -ne $ExpectedHash) { throw "Hash mismatch for $Path. Expected $ExpectedHash got $actual." }
}

function Get-ReleaseInfo {
    if (-not (Test-Path -LiteralPath $ReleaseInfoPath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $ReleaseInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Stop-App {
    foreach($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if($p.MainWindowHandle -ne 0){ [void]$p.CloseMainWindow() } } catch {}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $needle = 'ChatGptDesktopLocalBridge\WebView2'
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -like ('*'+$needle+'*') })) {
        try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Seconds 1
}

function Apply-Delta {
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
    $url = 'https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/' + $TargetTag + '/' + $DeltaName
    Download-Verified -Url $url -Path $DeltaPath -ExpectedHash $DeltaSha256
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')
    $p = Start-Process -FilePath $DeltaPath -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$UpdateLog)) -PassThru
    if(-not $p.WaitForExit(180000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw 'Delta updater timeout.'
    }
    $p.Refresh()
    if($p.ExitCode -ne 0) {
        $tail = if(Test-Path $UpdateLog){ (Get-Content $UpdateLog -Tail 80 | Out-String) } else { '' }
        throw "Delta updater exit code $($p.ExitCode). $tail"
    }
}

function Restore-BaseRelease {
    try {
        Stop-App
        $url = 'https://github.com/lvlaksim1/chatgpt-desktop-local-bridge/releases/download/' + $BaseTag + '/' + $BaseSetupName
        Download-Verified -Url $url -Path $BaseSetupPath -ExpectedHash $BaseSetupSha256
        [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART','1','Process')
        $p = Start-Process -FilePath $BaseSetupPath -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$RollbackLog)) -PassThru
        if(-not $p.WaitForExit(180000)) { throw 'Rollback Setup timeout.' }
        $p.Refresh()
        if($p.ExitCode -ne 0) { throw "Rollback Setup exit code $($p.ExitCode)." }
        $after = Get-ReleaseInfo
        $ok = $null -ne $after -and [string]$after.tag -eq $BaseTag -and [string]$after.commit -eq $BaseCommit
        $Result.rollback = [ordered]@{ attempted=$true; pass=$ok; tag=if($null -ne $after){[string]$after.tag}else{$null} }
    } catch {
        $Result.rollback = [ordered]@{ attempted=$true; pass=$false; error=$_.Exception.Message }
    }
}

function Wait-AppWindow([int]$TimeoutSeconds = 45) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline) {
        $p = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
        if($p.Count -gt 0){ return $p[0] }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Add-NativeMethods {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class UiR1Native {
    public delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public const uint RIGHTDOWN = 0x0008;
    public const uint RIGHTUP = 0x0010;
}
'@
}

function Get-WebViewRect([IntPtr]$MainHwnd) {
    $items = New-Object System.Collections.ArrayList
    $callback = [UiR1Native+EnumChildProc]{
        param([IntPtr]$hwnd,[IntPtr]$lParam)
        $sb = New-Object Text.StringBuilder 256
        [void][UiR1Native]::GetClassName($hwnd,$sb,$sb.Capacity)
        $r = New-Object UiR1Native+RECT
        if([UiR1Native]::GetWindowRect($hwnd,[ref]$r)) {
            $w=$r.Right-$r.Left; $h=$r.Bottom-$r.Top
            if($w -gt 400 -and $h -gt 300 -and $sb.ToString() -like 'Chrome*') {
                [void]$items.Add([pscustomobject]@{ hwnd=$hwnd; class=$sb.ToString(); left=$r.Left; top=$r.Top; right=$r.Right; bottom=$r.Bottom; area=$w*$h })
            }
        }
        return $true
    }
    [void][UiR1Native]::EnumChildWindows($MainHwnd,$callback,[IntPtr]::Zero)
    return @($items | Sort-Object area -Descending | Select-Object -First 1)
}

function Get-UiTexts($Root) {
    $values = New-Object System.Collections.ArrayList
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all) {
        try {
            if($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) {
                $n=[string]$el.Current.Name
                if(-not [string]::IsNullOrWhiteSpace($n)){[void]$values.Add($n)}
            }
        } catch {}
    }
    return @($values | Select-Object -Unique)
}

function Get-UiButtons($Root) {
    $values = New-Object System.Collections.ArrayList
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all) {
        try {
            if($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
                $n=[string]$el.Current.Name
                if(-not [string]::IsNullOrWhiteSpace($n)){[void]$values.Add($n)}
            }
        } catch {}
    }
    return @($values | Select-Object -Unique)
}

function Find-UiElementByName($Root,[string]$Name,[int]$TimeoutSeconds=8) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
    while([DateTime]::UtcNow -lt $deadline) {
        $el=$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
        if($null -ne $el){return $el}
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Invoke-UiElement($Element) {
    $pattern=$null
    if(-not $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw "Element '$($Element.Current.Name)' is not invokable."}
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Get-ProcessWindow([int]$Pid,[string]$Name,[int]$TimeoutSeconds=8) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline) {
        $wins=[System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach($w in $wins) {
            try {
                if($w.Current.ProcessId -eq $Pid -and [string]$w.Current.Name -eq $Name){return $w}
            } catch {}
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-TabItems($Root) {
    $cond=New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    return @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$cond))
}

function Select-Tab($Tab) {
    $pattern=$null
    if(-not $Tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){throw 'Tab is not selectable.'}
    ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
}

function Wait-BridgeReady($Root,[int]$TimeoutSeconds=90) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last=@()
    while([DateTime]::UtcNow -lt $deadline) {
        $last=@(Get-UiTexts $Root)
        $hit=@($last | Where-Object { $_ -like $UiBridgeReadyPattern } | Select-Object -First 1)
        if($hit.Count -gt 0){return [string]$hit[0]}
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-CdpTargets([int]$Port,[int]$Minimum,[int]$TimeoutSeconds=60) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets=@(Invoke-RestMethod -Uri ('http://127.0.0.1:'+ $Port +'/json') -UseBasicParsing -TimeoutSec 2 |
                Where-Object { $_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*' -and -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl) })
            if($targets.Count -ge $Minimum){return $targets}
        } catch {}
        Start-Sleep -Milliseconds 300
    }
    return @()
}

function Open-CdpSocket($Target) {
    $s=New-Object System.Net.WebSockets.ClientWebSocket
    $s.ConnectAsync([Uri]$Target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $s
}

function Send-Cdp {
    param($Socket,[int]$Id,[string]$Method,[hashtable]$Params=@{},[int]$TimeoutMs=12000)
    $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
    $seg=New-Object ArraySegment[byte] -ArgumentList (,$bytes)
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)
    try {
        [void]($Socket.SendAsync($seg,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult())
        while($true) {
            $mem=New-Object IO.MemoryStream
            try {
                do {
                    $buf=New-Object byte[] 65536
                    $bseg=New-Object ArraySegment[byte] -ArgumentList (,$buf)
                    $rec=$Socket.ReceiveAsync($bseg,$cts.Token).GetAwaiter().GetResult()
                    if($rec.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP closed'}
                    $mem.Write($buf,0,$rec.Count)
                } while(-not $rec.EndOfMessage)
                $msg=([Text.Encoding]::UTF8.GetString($mem.ToArray())|ConvertFrom-Json)
                if($null -ne $msg.PSObject.Properties['id'] -and [int]$msg.id -eq $Id){return $msg}
            } finally {$mem.Dispose()}
        }
    } finally {$cts.Dispose()}
}

function Cdp-Eval($Socket,[ref]$Id,[string]$Expression) {
    $r=Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Runtime.evaluate' -Params @{expression=$Expression;returnByValue=$true;awaitPromise=$true}
    $Id.Value++
    if($null -ne $r.PSObject.Properties['error']){throw ('CDP eval error: '+($r.error|ConvertTo-Json -Compress))}
    if($null -eq $r.result -or $null -eq $r.result.result){return $null}
    return $r.result.result.value
}

function Wait-Adapter($Socket,[ref]$Id,[int]$TimeoutSeconds=75) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last=$null
    while([DateTime]::UtcNow -lt $deadline) {
        try {
            $last=Cdp-Eval $Socket $Id 'window.__localBridge?.health?.() ?? null'
            if($null -ne $last -and [int]$last.version -ge 7 -and [bool]$last.webViewAvailable){return $last}
        } catch {}
        Start-Sleep -Milliseconds 300
    }
    return $last
}

function Capture-CdpScreenshotStats($Socket,[ref]$Id) {
    $r=Send-Cdp -Socket $Socket -Id $Id.Value -Method 'Page.captureScreenshot' -Params @{format='png';fromSurface=$true}
    $Id.Value++
    if($null -ne $r.PSObject.Properties['error']){throw 'captureScreenshot failed'}
    $bytes=[Convert]::FromBase64String([string]$r.result.data)
    $ms=New-Object IO.MemoryStream(,$bytes)
    try {
        $bmp=New-Object System.Drawing.Bitmap($ms)
        try {
            $startY=[int]($bmp.Height*0.80)
            $step=[Math]::Max(1,[int]([Math]::Min($bmp.Width,$bmp.Height)/180))
            [long]$n=0;[long]$black=0;[long]$white=0
            for($y=$startY;$y -lt $bmp.Height;$y+=$step){
                for($x=0;$x -lt $bmp.Width;$x+=$step){
                    $c=$bmp.GetPixel($x,$y);$n++
                    if($c.R -le 5 -and $c.G -le 5 -and $c.B -le 5){$black++}
                    if($c.R -ge 250 -and $c.G -ge 250 -and $c.B -ge 250){$white++}
                }
            }
            return [ordered]@{
                width=$bmp.Width;height=$bmp.Height;samples=$n;
                bottom_black_ratio=if($n){[Math]::Round($black/$n,4)}else{0};
                bottom_white_ratio=if($n){[Math]::Round($white/$n,4)}else{0}
            }
        } finally {$bmp.Dispose()}
    } finally {$ms.Dispose()}
}

function Get-CrashEvents([DateTimeOffset]$Since) {
    $start=$Since.LocalDateTime
    $items=@()
    try {
        foreach($e in @(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$start} -ErrorAction SilentlyContinue | Select-Object -First 250)) {
            $provider=[string]$e.ProviderName
            $msg=[string]$e.Message
            if(($provider -in @('.NET Runtime','Application Error','Windows Error Reporting')) -and $msg -like '*ChatGptDesktopLocalBridge*') {
                $items += [ordered]@{time=$e.TimeCreated.ToString('o');provider=$provider;id=$e.Id;message=($msg -replace '\s+',' ').Substring(0,[Math]::Min(1200,($msg -replace '\s+',' ').Length))}
            }
        }
    } catch {}
    return @($items)
}

New-Item -ItemType Directory -Force -Path $TempRoot,$DownloadRoot | Out-Null
$AppWasRunning = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0
$SettingsHadFile = Test-Path -LiteralPath $SettingsPath -PathType Leaf
if($SettingsHadFile){ Copy-Item -LiteralPath $SettingsPath -Destination $SettingsBackup -Force }

$failure=$null
try {
    if(-not(Test-Path -LiteralPath $AppExe -PathType Leaf)){throw "Application executable missing: $AppExe"}
    $before=Get-ReleaseInfo
    if($null -eq $before){throw 'release-info.json missing or invalid.'}
    $Result.installed_before=[ordered]@{tag=[string]$before.tag;commit=[string]$before.commit;appVersion=[string]$before.appVersion}
    Set-Check 'base-recognized' (([string]$before.tag -eq $BaseTag -and [string]$before.commit -eq $BaseCommit) -or ([string]$before.tag -eq $TargetTag -and [string]$before.commit -eq $TargetCommit)) $Result.installed_before
    if(-not $Result.checks['base-recognized'].pass){throw "Unexpected installed release '$($before.tag)' '$($before.commit)'."}

    Stop-App
    if([string]$before.tag -eq $BaseTag) {
        Apply-Delta
        $RollbackNeeded=$true
    }
    $after=Get-ReleaseInfo
    $updateOk=$null -ne $after -and [string]$after.tag -eq $TargetTag -and [string]$after.commit -eq $TargetCommit
    Set-Check 'delta-install' $updateOk ([ordered]@{tag=if($after){[string]$after.tag}else{$null};commit=if($after){[string]$after.commit}else{$null}})
    if(-not $updateOk){throw 'Candidate release marker mismatch after update.'}

    $port=Get-Random -Minimum 9400 -Maximum 9999
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',('--remote-debugging-port='+$port+' --remote-allow-origins=*'),'Process')
    Start-Process -FilePath $AppExe | Out-Null
    $app=Wait-AppWindow 45
    $launchOk=$null -ne $app
    Set-Check 'startup-main-window' $launchOk (if($app){[ordered]@{pid=$app.Id;session=$app.SessionId;title=$app.MainWindowTitle}}else{$null})
    if(-not $launchOk){throw 'Application main window did not appear.'}

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-NativeMethods

    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$app.MainWindowHandle)
    if($null -eq $root){throw 'UIAutomation root unavailable.'}
    $buttons=@(Get-UiButtons $root)
    $texts=@(Get-UiTexts $root)
    $Result.main_buttons=$buttons
    Set-Check 'main-shell-buttons' (($buttons -contains $UiBridgeButton) -and ($buttons -contains $UiNewChat) -and ($buttons -contains $UiSettings)) $buttons

    $targets=Wait-CdpTargets $port 1 75
    $targetOk=$targets.Count -ge 1
    Set-Check 'webview-target' $targetOk ([ordered]@{count=$targets.Count;urls=@($targets|ForEach-Object{$_.url})})
    if(-not $targetOk){throw 'No ChatGPT CDP target.'}

    $Socket=Open-CdpSocket $targets[0]
    $id=1
    $health=Wait-Adapter $Socket ([ref]$id) 75
    $adapterOk=$null -ne $health -and [int]$health.version -ge 7
    Set-Check 'adapter-v7' $adapterOk $health
    if(-not $adapterOk){throw 'Adapter v7 did not become ready.'}

    $visual=Cdp-Eval $Socket ([ref]$id) "(()=>{const s=document.getElementById('__desktop_shell_paint_shield');return {readyState:document.readyState,shieldDisplay:s?.style?.display??null,bodyBg:getComputedStyle(document.body).backgroundColor,rootBg:getComputedStyle(document.documentElement).backgroundColor,w:innerWidth,h:innerHeight};})()"
    $visualOk=[string]$visual.readyState -eq 'complete' -and [int]$visual.w -gt 400 -and [int]$visual.h -gt 300 -and ([string]$visual.shieldDisplay -eq 'none' -or [string]::IsNullOrWhiteSpace([string]$visual.shieldDisplay))
    Set-Check 'initial-visual-ready' $visualOk $visual

    $shot=Capture-CdpScreenshotStats $Socket ([ref]$id)
    $paintOk=[double]$shot.bottom_black_ratio -lt 0.50 -and [double]$shot.bottom_white_ratio -lt 0.90
    Set-Check 'no-large-black-or-white-bottom-surface' $paintOk $shot

    $bridgeReady=Wait-BridgeReady $root 90
    Set-Check 'bridge-auto-restore' (-not [string]::IsNullOrWhiteSpace($bridgeReady)) $bridgeReady

    $newChat=Find-UiElementByName $root $UiNewChat 5
    if($null -eq $newChat){throw 'New-chat button not found.'}
    Invoke-UiElement $newChat
    $targets2=Wait-CdpTargets $port 2 75
    $preloadOk=$targets2.Count -ge 2
    Set-Check 'second-tab-preload' $preloadOk ([ordered]@{count=$targets2.Count;urls=@($targets2|ForEach-Object{$_.url})})
    if(-not $preloadOk){throw 'Second WebView target did not appear.'}

    Start-Sleep -Seconds 2
    $tabs=@(Get-TabItems $root)
    $Result.tab_item_count=$tabs.Count
    if($tabs.Count -ge 2) {
        Select-Tab $tabs[0]
        Start-Sleep -Milliseconds 350
        Select-Tab $tabs[$tabs.Count-1]
        Start-Sleep -Milliseconds 350
    }
    $alive=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {$_.Id -eq $app.Id}).Count -eq 1
    $targets3=Wait-CdpTargets $port 2 10
    Set-Check 'warm-tab-switch' ($alive -and $targets3.Count -ge 2) ([ordered]@{process_alive=$alive;target_count=$targets3.Count;tab_items=$tabs.Count})

    try{$Socket.Dispose()}catch{};$Socket=$null
    $activeTarget=$targets3[0]
    $Socket=Open-CdpSocket $activeTarget
    $id=100
    $health2=Wait-Adapter $Socket ([ref]$id) 30
    if($null -eq $health2){throw 'Active tab adapter unavailable.'}

    $downloadCmd=Send-Cdp -Socket $Socket -Id $id -Method 'Page.setDownloadBehavior' -Params @{behavior='allow';downloadPath=$DownloadRoot}
    $id++
    if($null -ne $downloadCmd.PSObject.Properties['error']) {
        $downloadCmd=Send-Cdp -Socket $Socket -Id $id -Method 'Browser.setDownloadBehavior' -Params @{behavior='allow';downloadPath=$DownloadRoot}
        $id++
    }
    $downloadName='ui-r1-runner-download.txt'
    [void](Cdp-Eval $Socket ([ref]$id) "(()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['UI-R1-DOWNLOAD-PASS'],{type:'text/plain'}));a.download='$downloadName';document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove();},1500);return true;})()")
    $downloadFile=Join-Path $DownloadRoot $downloadName
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while([DateTime]::UtcNow -lt $deadline -and -not(Test-Path -LiteralPath $downloadFile -PathType Leaf)){Start-Sleep -Milliseconds 250}
    $downloadOk=(Test-Path -LiteralPath $downloadFile -PathType Leaf) -and ((Get-Content -LiteralPath $downloadFile -Raw -ErrorAction SilentlyContinue) -eq 'UI-R1-DOWNLOAD-PASS')
    Set-Check 'native-download' $downloadOk (if(Test-Path $downloadFile){[ordered]@{path=$downloadFile;size=(Get-Item $downloadFile).Length}}else{$null})

    $contextHref='https://chatgpt.com/?ui_r1_context_test=1'
    $box=Cdp-Eval $Socket ([ref]$id) "(()=>{let a=document.getElementById('__ui_r1_context_link');if(!a){a=document.createElement('a');a.id='__ui_r1_context_link';a.href='$contextHref';a.textContent='UI R1 context target';Object.assign(a.style,{position:'fixed',left:'120px',top:'120px',width:'260px',height:'70px',zIndex:'2147483646',background:'#777',color:'#fff',display:'flex',alignItems:'center',justifyContent:'center'});document.body.appendChild(a);}const r=a.getBoundingClientRect();return {left:r.left,top:r.top,width:r.width,height:r.height,viewportW:innerWidth,viewportH:innerHeight,dpr:devicePixelRatio};})()"
    $wv=@(Get-WebViewRect ([IntPtr]$app.MainWindowHandle))
    $contextResult=[ordered]@{child_windows=$wv.Count;box=$box}
    $contextOk=$false
    if($wv.Count -gt 0) {
        $rect=$wv[0]
        $scaleX=($rect.right-$rect.left)/[double]$box.viewportW
        $scaleY=($rect.bottom-$rect.top)/[double]$box.viewportH
        $sx=[int]($rect.left + ($box.left+$box.width/2)*$scaleX)
        $sy=[int]($rect.top + ($box.top+$box.height/2)*$scaleY)
        [void][UiR1Native]::SetCursorPos($sx,$sy)
        [UiR1Native]::mouse_event([UiR1Native]::RIGHTDOWN,0,0,0,[UIntPtr]::Zero)
        [UiR1Native]::mouse_event([UiR1Native]::RIGHTUP,0,0,0,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 800
        $desktop=[System.Windows.Automation.AutomationElement]::RootElement
        $menuItem=Find-UiElementByName $desktop $UiOpenInNewTab 5
        $contextResult.menu_item_found=$null -ne $menuItem
        $contextResult.click_x=$sx;$contextResult.click_y=$sy;$contextResult.webview_class=$rect.class
        if($null -ne $menuItem) {
            $beforeCount=(Wait-CdpTargets $port 1 2).Count
            Invoke-UiElement $menuItem
            $afterTargets=Wait-CdpTargets $port ($beforeCount+1) 20
            $contextResult.before_targets=$beforeCount;$contextResult.after_targets=$afterTargets.Count
            $contextOk=$afterTargets.Count -ge ($beforeCount+1)
        }
    }
    Set-Check 'safe-context-open-in-tab' $contextOk $contextResult
    Start-Sleep -Seconds 1
    $aliveAfterContext=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {$_.Id -eq $app.Id}).Count -eq 1
    Set-Check 'context-menu-no-crash' $aliveAfterContext $null
    if(-not $aliveAfterContext){throw 'Application exited during context-menu test.'}

    $settingsButton=Find-UiElementByName $root $UiSettings 5
    if($null -eq $settingsButton){throw 'Settings button not found.'}
    Invoke-UiElement $settingsButton
    $settingsWin=Get-ProcessWindow $app.Id $UiSettings 8
    $settingsOk=$null -ne $settingsWin
    $settingsDetails=[ordered]@{}
    if($settingsOk) {
        $reset=Find-UiElementByName $settingsWin $UiResetTheme 3
        $full=Find-UiElementByName $settingsWin $UiFullSetup 3
        $settingsDetails.reset_found=$null -ne $reset
        $settingsDetails.full_setup_found=$null -ne $full
        if($null -ne $reset){Invoke-UiElement $reset}
        $save=Find-UiElementByName $settingsWin $UiSave 3
        if($null -ne $save){Invoke-UiElement $save;Start-Sleep -Seconds 1}
        $saved=$null
        if(Test-Path $SettingsPath){try{$saved=Get-Content $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
        $settingsDetails.saved_theme=if($saved){[string]$saved.ThemeColor}else{$null}
        $settingsOk=($null -ne $reset) -and ($null -ne $full) -and ($null -ne $saved) -and ([string]$saved.ThemeColor -eq '#202124')
    }
    Set-Check 'theme-reset-and-full-setup-placement' $settingsOk $settingsDetails
    $topButtons=@(Get-UiButtons $root)
    $noFullTop=-not($topButtons -contains $UiFullSetupShort) -and -not($topButtons -contains $UiFullSetup)
    Set-Check 'top-updater-not-full-setup' $noFullTop $topButtons

    $crashes=@(Get-CrashEvents $TestStarted)
    $Result.crash_events=$crashes
    Set-Check 'no-app-crash-events' ($crashes.Count -eq 0) $crashes

    $failed=@($Result.checks.GetEnumerator() | Where-Object { -not [bool]$_.Value.pass } | ForEach-Object {$_.Key})
    $Result.failed_checks=$failed
    if($failed.Count -gt 0){throw ('Failed checks: '+($failed -join ', '))}

    $RollbackNeeded=$false
    Write-ProjectResult -Status 'pass' -ExitCode 0
}
catch {
    $failure=$_.Exception.Message
    $Result.failed_at=[DateTimeOffset]::UtcNow.ToString('o')
    $Result.crash_events=@(Get-CrashEvents $TestStarted)
    Write-Host ('UI_R1_FAILURE='+$failure)
}
finally {
    if($null -ne $Socket){try{$Socket.Dispose()}catch{}}
    try{Stop-App}catch{}
    try {
        if($SettingsHadFile -and (Test-Path $SettingsBackup)){Copy-Item -LiteralPath $SettingsBackup -Destination $SettingsPath -Force}
        elseif(-not $SettingsHadFile -and (Test-Path $SettingsPath)){Remove-Item -LiteralPath $SettingsPath -Force}
    } catch {}
    [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',$OldBrowserArgs,'Process')
    [Environment]::SetEnvironmentVariable('CHATGPT_LOCAL_BRIDGE_UPDATE_SKIP_RESTART',$OldSkipRestart,'Process')
    if($RollbackNeeded){Restore-BaseRelease}
    try {
        if(Test-Path -LiteralPath $AppExe -PathType Leaf){Start-Process -FilePath $AppExe|Out-Null}
    } catch {}
    if($null -ne $failure){
        Write-ProjectResult -Status 'fail' -ExitCode 31 -ErrorText $failure
    }
}
