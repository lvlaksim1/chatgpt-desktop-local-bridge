using ChatGptDesktopLocalBridge.Bridge;

if (!OperatingSystem.IsWindows())
{
    Console.WriteLine("SKIP: Windows required.");
    return;
}

static async Task<(string Text, long Cursor)> ReadUntilAsync(
    TerminalSessionManager terminals,
    string sessionId,
    long cursor,
    string marker)
{
    var deadline = DateTime.UtcNow.AddSeconds(10);
    var text = "";

    while (DateTime.UtcNow < deadline)
    {
        var chunk = await terminals.ReadAsync(
            sessionId,
            cursor,
            65536,
            1000,
            stripAnsi: true,
            collapseCarriageReturns: true);

        cursor = chunk.NextCursor;
        text += chunk.Text;

        if (text.Contains(marker, StringComparison.Ordinal))
        {
            return (text, cursor);
        }
    }

    throw new Exception("Marker not received: " + marker + " output=" + text);
}

using var terminals = new TerminalSessionManager();
var opened = await terminals.OpenAsync(
    new TerminalOpenSpec(
        "cmd.exe",
        Array.Empty<string>(),
        Path.GetTempPath(),
        120,
        30));

long cursor = 0;
var initial = await terminals.ReadAsync(
    opened.SessionId,
    cursor,
    65536,
    500,
    stripAnsi: true,
    collapseCarriageReturns: true);
cursor = initial.NextCursor;

await terminals.WriteAsync(
    opened.SessionId,
    "set LOCAL_BRIDGE_TEST_STATE=state-42&cd /d %TEMP%&echo __LB1__%LOCAL_BRIDGE_TEST_STATE%^|%CD%\r");

var first = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB1__");
cursor = first.Cursor;

if (!first.Text.Contains("__LB1__state-42|", StringComparison.Ordinal))
{
    throw new Exception("First command did not establish expected shell state.");
}

await terminals.WriteAsync(
    opened.SessionId,
    "echo __LB2__%LOCAL_BRIDGE_TEST_STATE%^|%CD%\r");

var second = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB2__");
cursor = second.Cursor;

if (!second.Text.Contains("__LB2__state-42|", StringComparison.Ordinal))
{
    throw new Exception("Shell state was not preserved between bridge requests.");
}

if (second.Text.Contains("__LB1__", StringComparison.Ordinal))
{
    throw new Exception("Cursor replayed already-consumed output.");
}

terminals.Resize(opened.SessionId, 100, 24);
var resized = terminals.Status(opened.SessionId);
if (resized.Columns != 100 || resized.Rows != 24)
{
    throw new Exception("Terminal resize was not applied.");
}

await terminals.WriteAsync(opened.SessionId, "echo __LB3__cursor-ok\r");
var third = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB3__");

if (third.Text.Contains("__LB1__", StringComparison.Ordinal) ||
    third.Text.Contains("__LB2__", StringComparison.Ordinal))
{
    throw new Exception("Absolute cursor did not isolate new output.");
}

await terminals.CloseAsync(opened.SessionId, force: true);
if (terminals.Status(opened.SessionId).Running)
{
    throw new Exception("Terminal remained running after close.");
}

var secondClose = await terminals.CloseAsync(opened.SessionId, force: true);
if (!secondClose.AlreadyClosed)
{
    throw new Exception("Repeated terminal.close was not idempotent.");
}

Console.WriteLine("PASS persistent-terminal");
