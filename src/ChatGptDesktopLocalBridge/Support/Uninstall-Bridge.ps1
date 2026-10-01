param(
    [switch]$InstallWrapper,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D6B9AF8-6D08-44E1-B2F5-8A6341D99165}_is1"
$scriptPath = $MyInvocation.MyCommand.Path
$supportDir = Split-Path -Parent $scriptPath
$installDir = Split-Path -Parent $supportDir
$dataDir = Join-Path $env:LOCALAPPDATA "ChatGptDesktopLocalBridge"
$processName = "ChatGptDesktopLocalBridge"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Decode-Utf8Base64([string]$Value) {
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function Get-OriginalUninstaller {
    if (-not (Test-Path -LiteralPath $uninstallKey)) {
        throw "Application uninstall registration was not found."
    }

    $registration = Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop
    $remembered = [string]$registration.BridgeOriginalUninstallExe

    if (-not [string]::IsNullOrWhiteSpace($remembered) -and (Test-Path -LiteralPath $remembered -PathType Leaf)) {
        return $remembered
    }

    $candidate = Get-ChildItem -LiteralPath $installDir -Filter "unins*.exe" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1

    if ($null -eq $candidate) {
        throw "Original application uninstaller was not found."
    }

    return $candidate.FullName
}

function Install-UninstallWrapper {
    $original = Get-OriginalUninstaller

    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell was not found."
    }

    $wrapperCommand = '"'+ $windowsPowerShell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'

    Set-ItemProperty -LiteralPath $uninstallKey -Name BridgeOriginalUninstallExe -Value $original -Type String
    Set-ItemProperty -LiteralPath $uninstallKey -Name UninstallString -Value $wrapperCommand -Type String
    Set-ItemProperty -LiteralPath $uninstallKey -Name QuietUninstallString -Value ($wrapperCommand + " -Quiet") -Type String

    Write-Host "Uninstall wrapper registered."
}

if ($InstallWrapper) {
    Install-UninstallWrapper
    exit 0
}

$deleteUserData = $false

if (-not $Quiet) {
    Add-Type -AssemblyName System.Windows.Forms

    $question = Decode-Utf8Base64 "0KPQtNCw0LvQuNGC0Ywg0YLQsNC60LbQtSDQvdCw0YHRgtGA0L7QudC60Lgg0Lgg0YDQsNCx0L7Rh9C40LUg0LTQsNC90L3Ri9C1Pw=="
    $caption = Decode-Utf8Base64 "0KPQtNCw0LvQtdC90LjQtSBDaGF0R1BUIERlc2t0b3AgTG9jYWwgQnJpZGdl"

    $answer = [System.Windows.Forms.MessageBox]::Show($question, $caption, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    $deleteUserData = $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

$originalUninstaller = Get-OriginalUninstaller

Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$uninstallProcess = Start-Process -FilePath $originalUninstaller -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait -PassThru

if ($uninstallProcess.ExitCode -ne 0) {
    throw "Original uninstaller failed with exit code $($uninstallProcess.ExitCode)."
}

if ($deleteUserData -and (Test-Path -LiteralPath $dataDir)) {
    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction Stop
}

$escapedInstallDir = $installDir.Replace("'", "''")
$cleanupCode = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$escapedInstallDir' -Recurse -Force -ErrorAction SilentlyContinue"
$encodedCleanup = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cleanupCode))

Start-Process -FilePath $windowsPowerShell -ArgumentList @("-NoProfile", "-EncodedCommand", $encodedCleanup) -WindowStyle Hidden
