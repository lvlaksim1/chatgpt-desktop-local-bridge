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

static async Task<(string Text, long Cursor)> DrainUntilQuietAsync(
    TerminalSessionManager terminals,
    string sessionId,
    long cursor)
{
    var deadline = DateTime.UtcNow.AddSeconds(3);
    var text = "";
    var quietReads = 0;

    while (DateTime.UtcNow < deadline && quietReads < 2)
    {
        var chunk = await terminals.ReadAsync(
            sessionId,
            cursor,
            65536,
            250,
            stripAnsi: true,
            collapseCarriageReturns: true);

        cursor = chunk.NextCursor;
        text += chunk.Text;

        if (chunk.Text.Length == 0)
        {
            quietReads++;
        }
        else
        {
            quietReads = 0;
        }
    }

    return (text, cursor);
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

var afterOpen = terminals.Status(opened.SessionId);
Console.WriteLine(
    "OPEN-STATUS running=" + afterOpen.Running +
    " exit=" + (afterOpen.ExitCode?.ToString() ?? "null") +
    " base=" + afterOpen.BaseCursor +
    " end=" + afterOpen.EndCursor);

await terminals.WriteAsync(
    opened.SessionId,
    "set LOCAL_BRIDGE_TEST_STATE=state-42\r");
await terminals.WriteAsync(
    opened.SessionId,
    "cd /d %TEMP%\r");
await terminals.WriteAsync(
    opened.SessionId,
    "echo __LB1__%LOCAL_BRIDGE_TEST_STATE%^|%CD%\r");

var first = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB1__state-42|");
var firstTail = await DrainUntilQuietAsync(terminals, opened.SessionId, first.Cursor);
cursor = firstTail.Cursor;
var firstText = first.Text + firstTail.Text;

if (!firstText.Contains("__LB1__state-42|", StringComparison.Ordinal))
{
    throw new Exception("First command did not establish expected shell state.");
}

await terminals.WriteAsync(
    opened.SessionId,
    "echo __LB2__%LOCAL_BRIDGE_TEST_STATE%^|%CD%\r");

var secondStart = cursor;
var second = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB2__state-42|");
var secondTail = await DrainUntilQuietAsync(terminals, opened.SessionId, second.Cursor);
cursor = secondTail.Cursor;
var secondText = second.Text + secondTail.Text;

if (!secondText.Contains("__LB2__state-42|", StringComparison.Ordinal))
{
    throw new Exception("Shell state was not preserved between bridge requests.");
}

if (secondText.Contains("__LB1__", StringComparison.Ordinal))
{
    throw new Exception("Cursor replayed already-consumed output after a quiet boundary.");
}

var secondLength = checked((int)Math.Min(cursor - secondStart, 65536));
var secondReplay = await terminals.ReadAsync(
    opened.SessionId,
    secondStart,
    Math.Max(secondLength, 1),
    0,
    stripAnsi: true,
    collapseCarriageReturns: true);

if (!secondReplay.Text.Contains("__LB2__state-42|", StringComparison.Ordinal))
{
    throw new Exception("Retrying an absolute cursor did not reproduce the previously read segment.");
}

// Verify cursor isolation before any terminal resize. ConPTY is allowed to redraw
// its visible screen buffer after ResizePseudoConsole, and that redraw is genuinely
// new output rather than a replay from the bridge ring buffer.
await terminals.WriteAsync(opened.SessionId, "echo __LB3__cursor-ok\r");
var third = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB3__cursor-ok");
var thirdTail = await DrainUntilQuietAsync(terminals, opened.SessionId, third.Cursor);
var thirdText = third.Text + thirdTail.Text;
cursor = thirdTail.Cursor;

if (thirdText.Contains("__LB1__", StringComparison.Ordinal) ||
    thirdText.Contains("__LB2__", StringComparison.Ordinal))
{
    throw new Exception(
        "Absolute cursor crossed a settled output boundary before resize. Output: " +
        thirdText.Replace("\r", "\\r").Replace("\n", "\\n"));
}

terminals.Resize(opened.SessionId, 100, 24);
var resized = terminals.Status(opened.SessionId);
if (resized.Columns != 100 || resized.Rows != 24)
{
    throw new Exception("Terminal resize was not applied.");
}

await terminals.WriteAsync(opened.SessionId, "echo __LB4__resize-ok\r");
var fourth = await ReadUntilAsync(terminals, opened.SessionId, cursor, "__LB4__resize-ok");
var fourthTail = await DrainUntilQuietAsync(terminals, opened.SessionId, fourth.Cursor);
cursor = fourthTail.Cursor;

if (!(fourth.Text + fourthTail.Text).Contains("__LB4__resize-ok", StringComparison.Ordinal))
{
    throw new Exception("Terminal stopped producing command output after resize.");
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
