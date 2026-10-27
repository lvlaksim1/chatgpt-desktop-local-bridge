param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference = 'Stop'
$root = 'D:\LocalAI\Goose'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\start-goose-ru-single.ps1'
$destination = Join-Path $root 'Start-Goose-RU-Single.ps1'
$cmd = Join-Path $root 'Goose-RU.cmd'
$vbs = Join-Path $root 'Goose-RU.vbs'
$backups = Join-Path $root 'backups'
$r = [ordered]@{status='failed';stage='preflight';error='';launcher=$destination;backup='';cmd_modified=$false;script_syntax_ok=$false;one_start_command=$false;original_program_untouched=$true;runtime_reuse_test='not_performed'}
try {
    foreach($file in @($source,$cmd,$vbs,(Join-Path $root 'desktop-ru\v1.56.0\Goose.exe'))){
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Required file missing: $file"}
    }
    $before = @(Get-Content -LiteralPath $cmd)
    $starts = @($before|Where-Object{$_ -match '^\s*start\s'})
    if($starts.Count -ne 1){throw "Expected exactly one start command in current Goose-RU.cmd; got $($starts.Count)"}
    $hasExpectedDir = ([string]$starts[0] -match 'D:\\LocalAI\\Goose\\workspace')
    if(-not $hasExpectedDir){throw "Current Goose command does not reference expected workspace"}
    $vbsText = Get-Content -LiteralPath $vbs -Raw
    if($vbsText -notmatch 'Goose-RU\.cmd'){throw 'Existing hidden launcher does not point to Goose-RU.cmd'}
    $r.stage='script-syntax'
    $token=$null
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($source,[ref]$token,[ref]$errors)
    if(@($errors).Count){throw ('New launcher has PowerShell syntax errors: '+(@($errors)|Select-Object -First 2|ForEach-Object{$_.Message}) -join '; ')}
    $r.script_syntax_ok=$true
    $r.stage='backup'
    New-Item -ItemType Directory -Path $backups -Force | Out-Null
    $backup = Join-Path $backups 'Goose-RU.before-single-window.cmd'
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){Copy-Item -LiteralPath $cmd -Destination $backup}
    $r.backup=$backup
    $destBackup=Join-Path $backups 'Start-Goose-RU-Single.previous.ps1'
    if((Test-Path -LiteralPath $destination -PathType Leaf) -and -not(Test-Path -LiteralPath $destBackup -PathType Leaf)){Copy-Item -LiteralPath $destination -Destination $destBackup}
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $r.stage='cmd'
    $updated=@()
    foreach($line in $before){
        if($line -match '^\s*start\s'){
            $updated+='"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\LocalAI\Goose\Start-Goose-RU-Single.ps1"'
        }else{$updated+=$line}
    }
    [IO.File]::WriteAllLines($cmd,$updated,[Text.Encoding]::ASCII)
    $after=@(Get-Content -LiteralPath $cmd)
    $r.one_start_command=(@($after|Where-Object{$_ -match 'Start-Goose-RU-Single\.ps1'}).Count -eq 1 -and @($after|Where-Object{$_ -match '^\s*start\s'}).Count -eq 0)
    if(-not $r.one_start_command){throw 'Launcher validation failed: duplicate or missing entry'}
    $r.cmd_modified=$true
    $r.stage='smoke'
    # If Goose is already running, test that invoking the new launcher does not add another main process.
    $running=@(Get-CimInstance Win32_Process -Filter "Name='Goose.exe'" -ErrorAction Stop|
        Where-Object{([string]$_.ExecutablePath) -ieq (Join-Path $root 'desktop-ru\v1.56.0\Goose.exe') -and ([string]$_.CommandLine) -notmatch '(?i)--type=(renderer|utility|gpu-process|crashpad-handler)'})
    if($running.Count -gt 0){
        $prior=@($running|ForEach-Object{$_.ProcessId}|Sort-Object)
        $shell=Join-Path $PSHOME 'powershell.exe'
        $out=Join-Path $root 'logs\single-window-smoke-stdout.log'
        $err=Join-Path $root 'logs\single-window-smoke-stderr.log'
        $p=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$destination+'"')) -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        if(-not $p.WaitForExit(25000)){try{$p.Kill()}catch{};throw 'Launcher reuse test timed out'}
        $p.Refresh()
        $next=@(Get-CimInstance Win32_Process -Filter "Name='Goose.exe'" -ErrorAction Stop|
            Where-Object{([string]$_.ExecutablePath) -ieq (Join-Path $root 'desktop-ru\v1.56.0\Goose.exe') -and ([string]$_.CommandLine) -notmatch '(?i)--type=(renderer|utility|gpu-process|crashpad-handler)' }|
            ForEach-Object{$_.ProcessId}|Sort-Object)
        if(($prior -join ',') -ne ($next -join ',')){throw 'Existing Goose main process changed after reuse test'}
        $r.runtime_reuse_test='passed_existing_process_reused'
    } else {
        $r.runtime_reuse_test='skipped_no_running_Goose_to_preserve_desktop'
    }
    $r.status='success'
    $r.stage='done'
    $r.error='Russian Goose launcher now serializes startup and reuses an existing main process. GUI windows were not closed; a clean desktop relaunch is needed to verify one visible window.'
} catch {
    $r.error=([string]$_.Exception.Message -replace '[\r\n\t]+',' ')
}
if($r.error.Length -gt 670){$r.error=$r.error.Substring(0,670)}
$r | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
