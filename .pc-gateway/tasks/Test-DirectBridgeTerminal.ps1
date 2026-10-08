[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Result {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorText = '',
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        status = $Status
        exit_code = $ExitCode
        error = $ErrorText
    }
    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $directory = Split-Path -Parent $GatewayResultPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $payload | ConvertTo-Json -Depth 16 |
        Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $ExitCode
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appProject = Join-Path $repoRoot 'src\ChatGptDesktopLocalBridge\ChatGptDesktopLocalBridge.csproj'
if (-not (Test-Path -LiteralPath $appProject -PathType Leaf)) {
    Write-Result -Status 'fail' -ExitCode 31 -ErrorText 'Application project not found.'
}

$probeRoot = Join-Path $env:TEMP ('local-bridge-terminal-probe-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null

try {
    $projectPath = Join-Path $probeRoot 'TerminalProbe.csproj'
    $programPath = Join-Path $probeRoot 'Program.cs'
    $escapedProject = [System.Security.SecurityElement]::Escape($appProject)

    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="$escapedProject" />
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $projectPath -Encoding UTF8

    @'
using ChatGptDesktopLocalBridge.Bridge;

static async Task<(string Text, long Cursor)> ReadUntilAsync(
    TerminalSessionManager terminals,
    string sessionId,
    long cursor,
    string marker,
    int timeoutMs = 10_000)
{
    var started = Environment.TickCount64;
    var collected = "";

    while (Environment.TickCount64 - started < timeoutMs)
    {
        var read = await terminals.ReadAsync(
            sessionId,
            cursor,
            65_536,
            1_000,
            stripAnsi: true,
            collapseCarriageReturns: true);

        cursor = read.NextCursor;
        collected += read.Text;

        if (collected.Contains(marker, StringComparison.Ordinal))
        {
            return (collected, cursor);
        }

        if (!read.Running && read.Text.Length == 0)
        {
            break;
        }
    }

    throw new Exception("Timed out waiting for marker " + marker + ". Output: " + collected);
}

using var terminals = new TerminalSessionManager();
var temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
var opened = await terminals.OpenAsync(
    new TerminalOpenSpec(
        "powershell.exe",
        new[] { "-NoLogo", "-NoProfile" },
        temp,
        120,
        30));

long cursor = 0;
var initial = await terminals.ReadAsync(
    opened.SessionId,
    cursor,
    65_536,
    500,
    stripAnsi: true,
    collapseCarriageReturns: true);
cursor = initial.NextCursor;

await terminals.WriteAsync(
    opened.SessionId,
    "$env:LOCAL_BRIDGE_TEST_STATE='state-42'; Set-Location $env:TEMP; Write-Output ('__LB1__'+$env:LOCAL_BRIDGE_TEST_STATE+'|'+(Get-Location).Path)\r");

var first = await ReadUntilAsync(
    terminals,
    opened.SessionId,
    cursor,
    "__LB1__");
cursor = first.Cursor;

if (!first.Text.Contains("__LB1__state-42|", StringComparison.Ordinal))
{
    throw new Exception("First terminal command did not preserve the assigned environment value.");
}

await terminals.WriteAsync(
    opened.SessionId,
    "Write-Output ('__LB2__'+$env:LOCAL_BRIDGE_TEST_STATE+'|'+(Get-Location).Path)\r");

var second = await ReadUntilAsync(
    terminals,
    opened.SessionId,
    cursor,
    "__LB2__");
cursor = second.Cursor;

if (!second.Text.Contains("__LB2__state-42|", StringComparison.Ordinal))
{
    throw new Exception("Persistent shell state was lost between terminal requests.");
}

if (second.Text.Contains("__LB1__", StringComparison.Ordinal))
{
    throw new Exception("Cursor-based terminal read replayed already-consumed output.");
}

// Verify absolute-cursor isolation before resizing. ResizePseudoConsole may emit
// a fresh redraw of the visible terminal screen, which is new ConPTY output.
await terminals.WriteAsync(opened.SessionId, "Write-Output '__LB3__cursor-ok'\r");
var third = await ReadUntilAsync(
    terminals,
    opened.SessionId,
    cursor,
    "__LB3__");
cursor = third.Cursor;

if (third.Text.Contains("__LB1__", StringComparison.Ordinal) ||
    third.Text.Contains("__LB2__", StringComparison.Ordinal))
{
    throw new Exception("Absolute cursor did not isolate new terminal output before resize.");
}

terminals.Resize(opened.SessionId, 100, 24);
var afterResize = terminals.Status(opened.SessionId);
if (afterResize.Columns != 100 || afterResize.Rows != 24)
{
    throw new Exception("ConPTY resize state did not update.");
}

await terminals.WriteAsync(opened.SessionId, "Write-Output '__LB4__resize-ok'\r");
var fourth = await ReadUntilAsync(
    terminals,
    opened.SessionId,
    cursor,
    "__LB4__");

if (!fourth.Text.Contains("__LB4__resize-ok", StringComparison.Ordinal))
{
    throw new Exception("Terminal stopped producing output after resize.");
}

var closed = await terminals.CloseAsync(
    opened.SessionId,
    force: true);

var finalStatus = terminals.Status(opened.SessionId);
if (finalStatus.Running)
{
    throw new Exception("Terminal still reports running after close.");
}

Console.WriteLine(
    "PASS session=" + opened.SessionId +
    " pid=" + opened.ProcessId +
    " cursor=" + fourth.Cursor +
    " exit=" + (closed.ExitCode?.ToString() ?? "null"));
'@ | Set-Content -LiteralPath $programPath -Encoding UTF8

    $stdoutPath = Join-Path $probeRoot 'stdout.txt'
    $stderrPath = Join-Path $probeRoot 'stderr.txt'

    $startArgs = @{
        FilePath = 'dotnet.exe'
        ArgumentList = @('run', '--project', $projectPath, '-c', 'Release')
        WorkingDirectory = $repoRoot
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
    }
    $process = Start-Process @startArgs

    $stdout = if (Test-Path $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    } else { '' }

    $stderr = if (Test-Path $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
    } else { '' }

    if ($process.ExitCode -ne 0) {
        Write-Result -Status 'fail' -ExitCode 32 -ErrorText 'Terminal probe failed.' -Extra @{
            dotnet_exit_code = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
        }
    }

    if ($stdout -notmatch 'PASS session=') {
        Write-Result -Status 'fail' -ExitCode 33 -ErrorText 'Terminal probe did not emit PASS marker.' -Extra @{
            stdout = $stdout
            stderr = $stderr
        }
    }

    Write-Result -Status 'pass' -ExitCode 0 -Extra @{
        stdout = $stdout.Trim()
        stderr = $stderr.Trim()
    }
}
catch {
    Write-Result -Status 'fail' -ExitCode 34 -ErrorText $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
