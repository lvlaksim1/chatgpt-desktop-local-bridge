using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static JsonElement Args(string json)
{
    using var document = JsonDocument.Parse(json);
    return document.RootElement.Clone();
}

var root = Path.Combine(
    Path.GetTempPath(),
    "chatgpt-local-bridge-ledger-test-" + Guid.NewGuid().ToString("N"));

try
{
    var session = "0123456789abcdef0123456789abcdef";
    var conversationUri = "https://chatgpt.com/c/bridge-test?temporary=1#fragment";
    var normalizedConversationUri = "https://chatgpt.com/c/bridge-test";

    var request = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":4096}"));

    var ledger = new DurableRequestLedger(root);

    var first = await ledger.ReserveAsync(request, conversationUri);
    Require(first.Status == DurableReservationStatus.Created, "First reservation was not created.");
    Require(first.Record.ExecutionState == DurableExecutionState.Reserved, "First reservation state is not reserved.");
    Require(first.Record.DeliveryState == DurableDeliveryState.NotReady, "Initial delivery state is not notReady.");
    Require(first.Record.ConversationUri == normalizedConversationUri,
        "Conversation URI was not normalized and persisted.");

    var reservedRestart = new DurableRequestLedger(root);
    var replayWhileReserved = await reservedRestart.ReserveAsync(request, conversationUri);
    Require(replayWhileReserved.Status == DurableReservationStatus.Duplicate,
        "Reserved request replay after restart was not detected.");
    Require(
        DurableRequestLedger.GetReplayAction(replayWhileReserved.Record) == DurableReplayAction.ResumeReserved,
        "Reserved replay was not classified as safe to resume.");

    var executing = await reservedRestart.MarkExecutingAsync(replayWhileReserved.Record);
    Require(executing.ExecutionState == DurableExecutionState.Executing, "Executing state was not persisted.");

    var afterRestart = new DurableRequestLedger(root);
    var replayWhileExecuting = await afterRestart.ReserveAsync(request, conversationUri);
    Require(replayWhileExecuting.Status == DurableReservationStatus.Duplicate, "Replay after restart was not detected.");
    Require(replayWhileExecuting.Record.ExecutionState == DurableExecutionState.Executing,
        "Replay did not recover the executing state.");
    Require(
        DurableRequestLedger.GetReplayAction(replayWhileExecuting.Record) ==
        DurableReplayAction.BlockExecutionUncertain,
        "Executing replay was not classified as uncertain.");

    var resultEnvelopeJson =
        "{\"session\":\"0123456789abcdef0123456789abcdef\",\"request_id\":\"req-durable-001\",\"ok\":true,\"result\":{\"text\":\"ok\"}}";

    var completed = await afterRestart.MarkCompletedAsync(
        replayWhileExecuting.Record,
        ok: true,
        errorCode: null,
        elapsedMs: 37,
        resultEnvelopeJson: resultEnvelopeJson);

    Require(completed.ExecutionState == DurableExecutionState.Completed, "Completed state was not persisted.");
    Require(completed.DeliveryState == DurableDeliveryState.Pending, "Completion did not create pending delivery.");
    Require(completed.ResultEnvelopeJson == resultEnvelopeJson, "Completed request did not persist its result envelope.");

    var equivalentRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"max_chars\":4096,\"path\":\"C:/Windows/win.ini\"}"));

    var secondRestart = new DurableRequestLedger(root);
    var replayPending = await secondRestart.ReserveAsync(equivalentRequest, conversationUri);
    Require(replayPending.Status == DurableReservationStatus.Duplicate,
        "Canonical equivalent request was not recognized as the same durable request.");
    Require(replayPending.Record.DeliveryState == DurableDeliveryState.Pending,
        "Pending delivery state did not survive restart.");
    Require(replayPending.Record.ResultEnvelopeJson == resultEnvelopeJson,
        "Pending result payload did not survive restart.");
    Require(
        DurableRequestLedger.GetReplayAction(replayPending.Record) == DurableReplayAction.RedeliverResult,
        "Completed pending replay was not classified for result re-delivery.");

    var pendingDeliveries = await secondRestart.GetPendingDeliveriesAsync(conversationUri);
    Require(pendingDeliveries.Count == 1, "Pending delivery enumeration did not return exactly one record.");
    Require(pendingDeliveries[0].RequestId == request.Id, "Pending delivery enumeration returned the wrong request.");
    Require(pendingDeliveries[0].ResultEnvelopeJson == resultEnvelopeJson,
        "Pending delivery enumeration lost the persisted result payload.");

    var wrongConversationPending =
        await secondRestart.GetPendingDeliveriesAsync("https://chatgpt.com/c/other");
    Require(wrongConversationPending.Count == 0,
        "Pending result leaked into a different conversation scope.");

    var delivered = await secondRestart.MarkDeliveredAsync(replayPending.Record);
    Require(delivered.DeliveryState == DurableDeliveryState.Delivered, "Delivered state was not persisted.");

    var thirdRestart = new DurableRequestLedger(root);
    var replayDelivered = await thirdRestart.ReserveAsync(request, conversationUri);
    Require(replayDelivered.Status == DurableReservationStatus.Duplicate,
        "Delivered request replay was not detected.");
    Require(replayDelivered.Record.DeliveryState == DurableDeliveryState.Delivered,
        "Delivered state did not survive restart.");
    Require(replayDelivered.Record.ResultEnvelopeJson is null,
        "Delivered record retained a result payload that should have been retired.");
    Require(
        DurableRequestLedger.GetReplayAction(replayDelivered.Record) == DurableReplayAction.IgnoreDelivered,
        "Completed delivered replay was not classified as already delivered.");

    var pendingWithoutPayload = replayPending.Record with { ResultEnvelopeJson = null };
    Require(
        DurableRequestLedger.GetReplayAction(pendingWithoutPayload) == DurableReplayAction.BlockMissingResult,
        "Pending completed record without a durable result payload was not blocked.");

    var noPendingDeliveries = await thirdRestart.GetPendingDeliveriesAsync(conversationUri);
    Require(noPendingDeliveries.Count == 0, "Delivered result remained in the pending-delivery set.");

    var conversationConflict =
        await thirdRestart.ReserveAsync(request, "https://chatgpt.com/c/other");
    Require(conversationConflict.Status == DurableReservationStatus.Conflict,
        "The same durable request identity was accepted from a different conversation.");

    var conflictingRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":8192}"));

    var conflict = await thirdRestart.ReserveAsync(conflictingRequest, conversationUri);
    Require(conflict.Status == DurableReservationStatus.Conflict,
        "Conflicting reuse of a durable request id was not rejected.");

    var smallPrepared = BridgeResultTransport.Prepare(
        new BridgeResult(session, "req-small", true, new { text = "ok" }),
        ok: true,
        errorCode: null);
    Require(smallPrepared.Ok, "Small result unexpectedly failed transport preparation.");
    Require(!smallPrepared.ReplacedOversizeResult, "Small result was incorrectly treated as oversized.");
    Require(
        System.Text.Encoding.UTF8.GetByteCount(smallPrepared.Message) <= BridgeResultTransport.MaxMessageBytes,
        "Small result exceeded the transport bound.");

    var hugePrepared = BridgeResultTransport.Prepare(
        new BridgeResult(
            session,
            "req-huge",
            true,
            new { text = new string('x', BridgeResultTransport.MaxMessageBytes + 4096) }),
        ok: true,
        errorCode: null);
    Require(!hugePrepared.Ok, "Oversized result was not converted to a bounded error.");
    Require(hugePrepared.ReplacedOversizeResult, "Oversized result replacement was not reported.");
    Require(
        hugePrepared.ErrorCode == "result_too_large_after_execution",
        "Oversized result error code changed.");
    Require(
        System.Text.Encoding.UTF8.GetByteCount(hugePrepared.Message) <= BridgeResultTransport.MaxMessageBytes,
        "Oversized-result error envelope exceeded the transport bound.");

    var definitions = ToolRouter.Definitions;
    Require(definitions.Count == 17, "Unexpected number of registered bridge tools.");
    Require(
        definitions.Select(definition => definition.Name).Distinct(StringComparer.Ordinal).Count() == definitions.Count,
        "Bridge tool registry contains duplicate names.");

    foreach (var definition in definitions)
    {
        Require(
            ToolRouter.GetCapability(definition.Name) == definition.Capability,
            $"Capability mapping drifted for {definition.Name}.");
    }

    var bootstrapToolLines = ToolRouter.GetBootstrapToolLines();
    foreach (var definition in definitions)
    {
        Require(
            bootstrapToolLines.Contains(
                $"   args: {definition.ArgsExample}",
                StringComparer.Ordinal),
            $"Bootstrap args example drifted for {definition.Name}.");
        Require(
            bootstrapToolLines.Any(line => line.EndsWith(". " + definition.Name, StringComparison.Ordinal)),
            $"Bootstrap no longer exposes registered tool {definition.Name}.");
    }

    Require(
        ToolRouter.GetCapability("unknown.tool") == "unknown.tool",
        "Unknown tool capability fallback changed.");

    Require(
        ToolRouter.GetDefinition("process.run")?.IsLongRunning == true,
        "process.run is no longer marked as a long-running tool.");
    Require(
        ToolRouter.GetDefinition("fs.write_text")?.IsMutating == true,
        "fs.write_text is no longer marked as mutating.");
    Require(
        ToolRouter.GetCapability("fs.append_text") == "fs.write_text",
        "Append capability no longer shares the write permission.");
    Require(
        ToolRouter.GetCapability("repo.map") == "repo.read",
        "Repo map is no longer governed by the repo.read capability.");
    Require(
        ToolRouter.GetCapability("mcp.list_tools") == "mcp.read",
        "MCP discovery is no longer governed by the mcp.read capability.");
    Require(
        ToolRouter.GetCapability("mcp.call") == "mcp.call",
        "MCP execution capability mapping drifted.");
    Require(
        ToolRouter.GetDefinition("mcp.call")?.IsLongRunning == true,
        "mcp.call is no longer marked as long-running.");

    using (var router = new ToolRouter())
    {
        var repoRoot = Path.Combine(root, "repo-tools");
        Directory.CreateDirectory(repoRoot);

        static void RunGit(string cwd, params string[] arguments)
        {
            var startInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "git.exe",
                WorkingDirectory = cwd,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var argument in arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }

            using var process = System.Diagnostics.Process.Start(startInfo)
                ?? throw new Exception("Could not start git.exe for repo-tool regression setup.");
            process.WaitForExit();
            if (process.ExitCode != 0)
            {
                throw new Exception(
                    $"git {string.Join(" ", arguments)} failed: {process.StandardError.ReadToEnd()}");
            }
        }

        RunGit(repoRoot, "init");
        RunGit(repoRoot, "config", "user.name", "Local Bridge CI");
        RunGit(repoRoot, "config", "user.email", "local-bridge-ci@example.invalid");

        var trackedFile = Path.Combine(repoRoot, "BridgeSample.cs");
        await File.WriteAllTextAsync(
            trackedFile,
            "namespace Demo;\npublic static class BridgeSample { public static string Value() => \"v1\"; }\n");
        RunGit(repoRoot, "add", "BridgeSample.cs");
        RunGit(repoRoot, "commit", "-m", "baseline");

        await File.WriteAllTextAsync(
            trackedFile,
            "namespace Demo;\npublic static class BridgeSample { public static string Value() => \"v2\"; }\n");

        var statusResult = JsonSerializer.SerializeToElement(
            await router.ExecuteAsync(
                "repo.status",
                Args(JsonSerializer.Serialize(new { path = repoRoot }))));
        Require(
            statusResult.GetProperty("clean").GetBoolean() == false,
            "repo.status failed to report the modified working tree.");

        var diffResult = JsonSerializer.SerializeToElement(
            await router.ExecuteAsync(
                "repo.diff",
                Args(JsonSerializer.Serialize(new { path = repoRoot, staged = false, max_chars = 20_000 }))));
        Require(
            diffResult.GetProperty("diff").GetString()?.Contains(
                "v2",
                StringComparison.Ordinal) == true,
            "repo.diff did not return the working-tree change.");

        var mapResult = JsonSerializer.SerializeToElement(
            await router.ExecuteAsync(
                "repo.map",
                Args(JsonSerializer.Serialize(new
                {
                    path = repoRoot,
                    query = "BridgeSample Value",
                    max_files = 20,
                    max_chars = 20_000
                }))));
        Require(
            mapResult.GetProperty("map").GetString()?.Contains(
                "BridgeSample.cs",
                StringComparison.OrdinalIgnoreCase) == true,
            "repo.map did not surface the query-relevant source file.");

        var checkpointResult = JsonSerializer.SerializeToElement(
            await router.ExecuteAsync(
                "repo.checkpoint",
                Args(JsonSerializer.Serialize(new { path = repoRoot }))));
        var checkpointPath = checkpointResult.GetProperty("checkpointPath").GetString();
        Require(
            checkpointPath is not null && File.Exists(Path.Combine(checkpointPath, "working.diff")),
            "repo.checkpoint did not persist the working diff.");
        if (!string.IsNullOrWhiteSpace(checkpointPath) && Directory.Exists(checkpointPath))
        {
            Directory.Delete(checkpointPath, recursive: true);
        }

        var verifyResult = JsonSerializer.SerializeToElement(
            await router.ExecuteAsync(
                "repo.verify",
                Args(JsonSerializer.Serialize(new
                {
                    path = repoRoot,
                    file = "cmd.exe",
                    arguments = new[] { "/d", "/c", "exit 0" },
                    timeout_ms = 10_000,
                    max_output_chars = 4_096
                }))));
        Require(
            verifyResult.GetProperty("ok").GetBoolean(),
            "repo.verify did not report a successful bounded command.");

        var processResult = await router.ExecuteAsync(
            "process.run",
            Args("{\"file\":\"cmd.exe\",\"arguments\":[\"/d\",\"/c\",\"echo bridge-process-ok\"],\"timeout_ms\":10000,\"max_output_chars\":4096}"));
        var processJson = JsonSerializer.SerializeToElement(processResult);
        Require(
            processJson.GetProperty("exitCode").GetInt32() == 0,
            "Contained process smoke test did not exit successfully.");
        Require(
            processJson.GetProperty("stdout").GetString()?.Contains(
                "bridge-process-ok",
                StringComparison.OrdinalIgnoreCase) == true,
            "Contained process smoke test lost stdout.");

        var longRunTask = router.ExecuteAsync(
            "process.run",
            Args("{\"file\":\"cmd.exe\",\"arguments\":[\"/d\",\"/c\",\"ping 127.0.0.1 -n 30 >nul\"],\"timeout_ms\":60000,\"max_output_chars\":4096}"));
        await Task.Delay(500);
        Require(router.StopActiveProcesses() >= 1, "STOP did not find the active process execution.");
        var stoppedResult = JsonSerializer.SerializeToElement(await longRunTask);
        Require(
            stoppedResult.GetProperty("stopped").GetBoolean(),
            "STOP did not propagate to the process result.");
    }

    Console.WriteLine("durable request ledger + runtime foundation regression: PASS");
}
finally
{
    if (Directory.Exists(root))
    {
        try
        {
            Directory.Delete(root, recursive: true);
        }
        catch (UnauthorizedAccessException)
        {
            foreach (var file in Directory.EnumerateFiles(
                         root,
                         "*",
                         SearchOption.AllDirectories))
            {
                try
                {
                    File.SetAttributes(file, FileAttributes.Normal);
                }
                catch
                {
                    // Best-effort test cleanup only.
                }
            }

            Directory.Delete(root, recursive: true);
        }
    }
}