# Goose RU desktop: serialize shortcut launches, focus the existing instance.
# This runs in the logged-in Windows user's session, NOT inside GitHub Actions.
$ErrorActionPreference = 'Stop'
$root = 'D:\LocalAI\Goose'
$exe = Join-Path $root 'desktop-ru\v1.56.0\Goose.exe'
$work = Join-Path $root 'workspace'
$log = Join-Path $root 'logs\goose-ru-single-start.log'
$mutex = $null
$locked = $false
function Record([string]$message) {
    try {
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $message)
    } catch {}
}
try {
    if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw "Missing Goose.exe: $exe"}
    if(-not(Test-Path -LiteralPath $work -PathType Container)){throw "Missing workspace: $work"}
    $mutex = [System.Threading.Mutex]::new($false, 'Local\GooseRuDesktopLauncher')
    try {
        $locked = $mutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
        $locked = $true
    }
    if(-not $locked) {
        Record 'Another launcher owns the startup mutex; not starting a second window.'
        exit 0
    }
    # Filter in the WMI provider: never enumerate every process or scan every window.
    $running = @(
        Get-CimInstance Win32_Process -Filter "Name='Goose.exe'" -ErrorAction Stop |
        Where-Object {
            ([string]$_.ExecutablePath).Trim('"') -ieq $exe -and
            ([string]$_.CommandLine) -notmatch '(?i)--type=(renderer|utility|gpu-process|crashpad-handler)'
        } |
        Sort-Object CreationDate
    )
    if($running.Count -gt 0) {
        $id = [int]$running[0].ProcessId
        Record ("Existing Russian Goose desktop main PID=$id; focus instead of launching.")
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.AppActivate($id)
        } catch {
            Record ("Window focus not available: "+$_.Exception.Message)
        }
        exit 0
    }
    $env:GOOSE_LOCALE = 'ru'
    $env:GOOSE_PATH_ROOT = Join-Path $root 'profile'
    $env:GOOSE_PROVIDER = 'ollama'
    $env:GOOSE_MODEL = 'qwen3.5:4b-goose'
    $env:GOOSE_MODE = 'approve'
    $env:GOOSE_INPUT_LIMIT = '8192'
    $env:GOOSE_MAX_TOKENS = '8192'
    $env:OLLAMA_HOST = 'http://127.0.0.1:11434'
    $env:OLLAMA_STREAM_USAGE = 'false'
    $env:GOOSE_TELEMETRY_ENABLED = 'false'
    $env:NO_PROXY = 'localhost,127.0.0.1,::1'
    $env:HTTP_PROXY = ''
    $env:HTTPS_PROXY = ''
    $env:ALL_PROXY = ''
    # Pass --dir exactly once. Do not use a second launch path.
    $p = Start-Process -FilePath $exe -WorkingDirectory $work -ArgumentList @('--dir',('"'+$work+'"')) -PassThru -ErrorAction Stop
    Record ("Started Russian Goose main PID="+$p.Id+" directory="+$work)
} catch {
    Record ("START FAILED: "+$_.Exception.Message)
    exit 1
} finally {
    if($locked -and $null -ne $mutex){try{$mutex.ReleaseMutex()}catch{}}
    if($null -ne $mutex){$mutex.Dispose()}
}
