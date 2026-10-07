using System.Diagnostics;
using System.Text.RegularExpressions;
using ChatGptDesktopLocalBridge.Bridge;

var root = Path.Combine(
    Path.GetTempPath(),
    "ChatGptDesktopLocalBridge-TerminalProbe-" + Guid.NewGuid().ToString("N"));
var nested = Path.Combine(root, "nested");
Directory.CreateDirectory(nested);

using var manager = new TerminalSessionManager();

try
{
    var opened = await manager.OpenAsync(
        new TerminalOpenSpec(
            "powershell.exe",
            new[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass" },
            root,
            120,
            30,
            262_144));

    var terminalId = opened.TerminalId;
    var escapedNested = nested.Replace("'", "''");
    long cursor = 0;

    await manager.WriteAsync(
        terminalId,
        "$env:LOCAL_BRIDGE_PROBE='state-ok'\r");

    await manager.WriteAsync(
        terminalId,
        $"Set-Location '{escapedNested}'\r");

    await manager.WriteAsync(
        terminalId,
        "Write-Output (\"__LB_STATE__\" + $env:LOCAL_BRIDGE_PROBE + \"|\" + (Get-Location).Path)\r");

    var expectedState = "__LB_STATE__state-ok|" + nested;
    var stateRead = await ReadUntilAsync(
        manager,
        terminalId,
        cursor,
        expectedState,
        TimeSpan.FromSeconds(15));
    cursor = stateRead.NextCursor;

    if (!stateRead.Text.Contains(expectedState, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException(
            "Persistent terminal did not preserve environment/cwd state.");
    }

    var status = manager.Status(terminalId);
    var snapshotBytes = checked((int)Math.Min(status.TotalBytes, 200_000));
    var repeatA = manager.Read(terminalId, 0, Math.Max(snapshotBytes, 1));
    var repeatB = manager.Read(terminalId, 0, Math.Max(snapshotBytes, 1));

    if (repeatA.NextCursor != repeatB.NextCursor ||
        !string.Equals(repeatA.Text, repeatB.Text, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "Reading the same terminal cursor was not idempotent.");
    }

    await manager.WriteAsync(
        terminalId,
        "Write-Output (\"__LB_SECOND__\" + (2 + 3))\r");

    var secondRead = await ReadUntilAsync(
        manager,
        terminalId,
        cursor,
        "__LB_SECOND__5",
        TimeSpan.FromSeconds(15));
    cursor = secondRead.NextCursor;

    await manager.WriteAsync(
        terminalId,
        "$p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru; Write-Output (\"__LB_CHILD__\" + $p.Id)\r");

    var childRead = await ReadUntilRegexAsync(
        manager,
        terminalId,
        cursor,
        new Regex(@"__LB_CHILD__(\d+)", RegexOptions.CultureInvariant),
        TimeSpan.FromSeconds(15));

    var match = Regex.Match(
        childRead.Text,
        @"__LB_CHILD__(\d+)",
        RegexOptions.CultureInvariant);

    if (!match.Success ||
        !int.TryParse(match.Groups[1].Value, out var childPid))
    {
        throw new InvalidOperationException("Could not obtain child process id.");
    }

    await manager.CloseAsync(terminalId);

    var childGone = false;
    for (var attempt = 0; attempt < 20; attempt++)
    {
        try
        {
            using var child = Process.GetProcessById(childPid);
            if (child.HasExited)
            {
                childGone = true;
                break;
            }
        }
        catch (ArgumentException)
        {
            childGone = true;
            break;
        }

        await Task.Delay(100);
    }

    if (!childGone)
    {
        throw new InvalidOperationException(
            $"Terminal close left child process {childPid} running.");
    }

    Console.WriteLine(
        $"PASS terminal={terminalId} state=preserved cursor=idempotent child={childPid}:terminated");
}
finally
{
    manager.CloseAll();

    try
    {
        Directory.Delete(root, recursive: true);
    }
    catch
    {
    }
}

static async Task<(long NextCursor, string Text)> ReadUntilAsync(
    TerminalSessionManager manager,
    string terminalId,
    long startCursor,
    string marker,
    TimeSpan timeout)
{
    var deadline = DateTime.UtcNow + timeout;
    var cursor = startCursor;
    var collected = string.Empty;

    while (DateTime.UtcNow < deadline)
    {
        var read = manager.Read(terminalId, cursor, 65_536);
        cursor = read.NextCursor;
        collected += read.Text;

        if (collected.Contains(marker, StringComparison.OrdinalIgnoreCase))
        {
            return (cursor, collected);
        }

        if (read.Exited)
        {
            break;
        }

        await Task.Delay(100);
    }

    throw new TimeoutException(
        $"Timed out waiting for terminal marker '{marker}'. Output: {collected}");
}

static async Task<(long NextCursor, string Text)> ReadUntilRegexAsync(
    TerminalSessionManager manager,
    string terminalId,
    long startCursor,
    Regex pattern,
    TimeSpan timeout)
{
    var deadline = DateTime.UtcNow + timeout;
    var cursor = startCursor;
    var collected = string.Empty;

    while (DateTime.UtcNow < deadline)
    {
        var read = manager.Read(terminalId, cursor, 65_536);
        cursor = read.NextCursor;
        collected += read.Text;

        if (pattern.IsMatch(collected))
        {
            return (cursor, collected);
        }

        if (read.Exited)
        {
            break;
        }

        await Task.Delay(100);
    }

    throw new TimeoutException(
        $"Timed out waiting for terminal output matching '{pattern}'. Output: {collected}");
}
