using System.Runtime.InteropServices;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record BridgeToolDefinition(
    string Name,
    string Capability,
    string Description,
    string ArgsExample,
    bool IsMutating = false,
    bool IsLongRunning = false);

public sealed record BridgePlannedAction(
    string Tool,
    JsonElement Args,
    string ProbeId,
    string MessageId,
    string? RunId,
    string? RunCreatedAt,
    long ElapsedMs);

public sealed class ToolRouter : IDisposable
{
    private const int MaxWriteFileBytes = 1_048_576;
    private const int DefaultProcessTimeoutMs = 120_000;
    private const int MaxProcessTimeoutMs = 900_000;
    private const int DefaultProcessOutputChars = 200_000;
    private const int MaxProcessOutputChars = 1_000_000;

    private static readonly IReadOnlyList<BridgeToolDefinition> ToolDefinitions =
        new BridgeToolDefinition[]
        {
            new(
                "system.info",
                "system.info",
                "Return basic Windows, runtime, and process architecture information.",
                "{}"),
            new(
                "fs.list",
                "fs.list",
                "List up to 500 entries from a local directory.",
                "{ \"path\": \"C:/some/directory\" }"),
            new(
                "fs.read_text",
                "fs.read_text",
                "Read a bounded amount of text from a local file.",
                "{ \"path\": \"C:/some/file.txt\", \"max_chars\": 200000 }"),
            new(
                "local.intent",
                "fs.write_text",
                "Route one natural-language local-computer request through the server-side ChatGPT task planner, then execute the returned local action.",
                "{ \"instruction\": \"Read the first line of C:/source.txt and write it to C:/result.txt\" }",
                IsMutating: true,
                IsLongRunning: true),
            new(
                "fs.copy_first_line",
                "fs.write_text",
                "Read the first text line with UTF-8/Windows-1251 detection and atomically write it as UTF-8.",
                "{ \"source_path\": \"C:/source.txt\", \"destination_path\": \"C:/result.txt\", \"overwrite\": true, \"create_directories\": true }",
                IsMutating: true),
            new(
                "fs.write_text",
                "fs.write_text",
                "Atomically create or replace a UTF-8 text file.",
                "{ \"path\": \"C:/some/file.txt\", \"text\": \"text\", \"overwrite\": false, \"create_directories\": false }",
                IsMutating: true),
            new(
                "fs.append_text",
                "fs.write_text",
                "Append UTF-8 text to a file.",
                "{ \"path\": \"C:/some/file.txt\", \"text\": \"more text\", \"create_if_missing\": false, \"create_directories\": false }",
                IsMutating: true),
            new(
                "fs.write_file",
                "fs.write_text",
                "Atomically create or replace a bounded binary/text file.",
                "{ \"path\": \"C:/some/file.bin\", \"content\": \"BASE64_OR_TEXT\", \"encoding\": \"base64\", \"overwrite\": false, \"create_directories\": false }",
                IsMutating: true),
            new(
                "process.run",
                "process.start",
                "Run one bounded non-interactive process inside a Windows Job Object.",
                "{ \"file\": \"git.exe\", \"arguments\": [\"status\"], \"cwd\": \"C:/repo\", \"timeout_ms\": 120000, \"max_output_chars\": 200000 }",
                IsMutating: true,
                IsLongRunning: true),
            new(
                "repo.status",
                "repo.read",
                "Return branch, HEAD, and working-tree status for a Git repository.",
                "{ \"path\": \"C:/repo\" }"),
            new(
                "repo.diff",
                "repo.read",
                "Return a bounded working-tree or staged Git diff.",
                "{ \"path\": \"C:/repo\", \"staged\": false, \"max_chars\": 200000 }"),
            new(
                "repo.map",
                "repo.read",
                "Build a bounded local repository map with query-ranked files and symbol hints.",
                "{ \"path\": \"C:/repo\", \"query\": \"bridge result delivery\", \"max_files\": 120, \"max_chars\": 120000 }"),
            new(
                "repo.checkpoint",
                "repo.checkpoint",
                "Capture Git status/diffs plus bounded untracked files into Local Bridge state without modifying the repository.",
                "{ \"path\": \"C:/repo\" }",
                IsMutating: true),
            new(
                "repo.verify",
                "repo.verify",
                "Run one bounded verification command from the repository root.",
                "{ \"path\": \"C:/repo\", \"file\": \"dotnet.exe\", \"arguments\": [\"test\"], \"timeout_ms\": 300000, \"max_output_chars\": 200000 }",
                IsMutating: true,
                IsLongRunning: true),
            new(
                "mcp.list_servers",
                "mcp.read",
                "List locally configured MCP servers without exposing environment variable values.",
                "{}"),
            new(
                "mcp.list_tools",
                "mcp.read",
                "List allowed tools exposed by one configured MCP server.",
                "{ \"server\": \"server-id\", \"force_refresh\": false }"),
            new(
                "mcp.call",
                "mcp.call",
                "Call one tool on a preconfigured MCP server. Server commands cannot be supplied by the model.",
                "{ \"server\": \"server-id\", \"tool\": \"tool-name\", \"arguments\": {}, \"timeout_ms\": 120000 }",
                IsMutating: true,
                IsLongRunning: true)
        };

    private static readonly IReadOnlyDictionary<string, BridgeToolDefinition> ToolDefinitionsByName =
        ToolDefinitions.ToDictionary(
            definition => definition.Name,
            StringComparer.Ordinal);

    private readonly ProcessExecutionManager _processes = new();
    private readonly RepoTools _repoTools;
    private readonly McpManager _mcp = new();
    private readonly Func<string, CancellationToken, Task<BridgePlannedAction>>? _localIntentPlanner;

    public ToolRouter(
        Func<string, CancellationToken, Task<BridgePlannedAction>>? localIntentPlanner = null)
    {
        _localIntentPlanner = localIntentPlanner;
        _repoTools = new RepoTools(_processes);
    }

    public static IReadOnlyList<BridgeToolDefinition> Definitions => ToolDefinitions;

    public int ActiveProcessCount => _processes.ActiveCount;

    public IReadOnlyList<string> ActiveProcessIds => _processes.ActiveExecutionIds;

    public async Task<object?> ExecuteAsync(
        string tool,
        JsonElement args,
        CancellationToken cancellationToken = default)
    {
        if (!ToolDefinitionsByName.ContainsKey(tool))
        {
            throw new BridgeToolException("unknown_tool", $"Unknown local tool: {tool}");
        }

        return tool switch
        {
            "system.info" => GetSystemInfo(),
            "fs.list" => ListDirectory(args),
            "fs.read_text" => await ReadTextAsync(args),
            "local.intent" => await ExecuteLocalIntentAsync(args, cancellationToken),
            "fs.copy_first_line" => await CopyFirstLineAsync(args),
            "fs.write_text" => await WriteTextAsync(args),
            "fs.append_text" => await AppendTextAsync(args),
            "fs.write_file" => await WriteFileAsync(args),
            "process.run" => await RunProcessAsync(args, cancellationToken),
            "repo.status" => await _repoTools.StatusAsync(
                RequiredString(args, "path"),
                cancellationToken),
            "repo.diff" => await _repoTools.DiffAsync(
                RequiredString(args, "path"),
                OptionalBool(args, "staged", false),
                Math.Clamp(OptionalInt(args, "max_chars", 200_000), 1_000, 1_000_000),
                cancellationToken),
            "repo.map" => await _repoTools.MapAsync(
                RequiredString(args, "path"),
                OptionalString(args, "query", string.Empty),
                Math.Clamp(OptionalInt(args, "max_files", 120), 1, 500),
                Math.Clamp(OptionalInt(args, "max_chars", 120_000), 1_000, 1_000_000),
                cancellationToken),
            "repo.checkpoint" => await _repoTools.CheckpointAsync(
                RequiredString(args, "path"),
                cancellationToken),
            "repo.verify" => await _repoTools.VerifyAsync(
                RequiredString(args, "path"),
                RequiredString(args, "file"),
                OptionalStringArray(args, "arguments"),
                Math.Clamp(
                    OptionalInt(args, "timeout_ms", 300_000),
                    1_000,
                    MaxProcessTimeoutMs),
                Math.Clamp(
                    OptionalInt(args, "max_output_chars", DefaultProcessOutputChars),
                    1_000,
                    MaxProcessOutputChars),
                cancellationToken),
            "mcp.list_servers" => await _mcp.ListServersAsync(cancellationToken),
            "mcp.list_tools" => await _mcp.ListToolsAsync(
                RequiredString(args, "server"),
                OptionalBool(args, "force_refresh", false),
                cancellationToken),
            "mcp.call" => await _mcp.CallAsync(
                RequiredString(args, "server"),
                RequiredString(args, "tool"),
                OptionalObject(args, "arguments"),
                Math.Clamp(
                    OptionalInt(args, "timeout_ms", DefaultProcessTimeoutMs),
                    1_000,
                    MaxProcessTimeoutMs),
                cancellationToken),
            _ => throw new BridgeToolException("unknown_tool", $"Unknown local tool: {tool}")
        };
    }

    public int StopActiveProcesses() => _processes.StopAll();

    public static BridgeToolDefinition? GetDefinition(string tool)
        => ToolDefinitionsByName.TryGetValue(tool, out var definition)
            ? definition
            : null;

    public static string GetCapability(string tool)
        => ToolDefinitionsByName.TryGetValue(tool, out var definition)
            ? definition.Capability
            : tool;

    public static IReadOnlyList<string> GetBootstrapToolLines()
    {
        var lines = new List<string>();

        for (var index = 0; index < ToolDefinitions.Count; index++)
        {
            var definition = ToolDefinitions[index];
            lines.Add($"{index + 1}. {definition.Name}");
            lines.Add($"   {definition.Description}");
            lines.Add($"   args: {definition.ArgsExample}");
            lines.Add(string.Empty);
        }

        return lines;
    }

    public static string GetPermissionSummary(string tool, JsonElement args)
    {
        try
        {
            return tool switch
            {
                "local.intent"
                    => $"local.intent: {RequiredString(args, "instruction")}",
                "fs.copy_first_line"
                    => $"fs.copy_first_line: {RequiredString(args, "source_path")} -> {RequiredString(args, "destination_path")}",
                "fs.write_text" or "fs.append_text" or "fs.write_file"
                    => $"{tool}: {RequiredString(args, "path")}",
                "process.run"
                    => $"process.run: {RequiredString(args, "file")} {string.Join(" ", OptionalStringArray(args, "arguments"))}",
                "repo.checkpoint"
                    => $"repo.checkpoint: {RequiredString(args, "path")}",
                "repo.verify"
                    => $"repo.verify: {RequiredString(args, "file")} {string.Join(" ", OptionalStringArray(args, "arguments"))} in {RequiredString(args, "path")}",
                "mcp.call"
                    => $"mcp.call: {RequiredString(args, "server")}/{RequiredString(args, "tool")}",
                _ => tool
            };
        }
        catch
        {
            return tool;
        }
    }

    private static object GetSystemInfo() => new
    {
        machineName = Environment.MachineName,
        userName = Environment.UserName,
        os = RuntimeInformation.OSDescription,
        osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
        processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
        framework = RuntimeInformation.FrameworkDescription,
        currentDirectory = Environment.CurrentDirectory
    };

    private static object ListDirectory(JsonElement args)
    {
        var path = RequiredString(args, "path");
        var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));

        if (!Directory.Exists(fullPath))
        {
            throw new BridgeToolException("directory_not_found", $"Directory does not exist: {fullPath}");
        }

        var items = new DirectoryInfo(fullPath)
            .EnumerateFileSystemInfos()
            .Take(501)
            .ToArray();

        var entries = items
            .Take(500)
            .Select(item => new
            {
                name = item.Name,
                type = item is DirectoryInfo ? "directory" : "file",
                fullPath = item.FullName,
                size = item is FileInfo file ? file.Length : (long?)null,
                modifiedUtc = item.LastWriteTimeUtc
            })
            .ToArray();

        return new
        {
            path = fullPath,
            entries,
            truncated = items.Length > entries.Length
        };
    }

    private static async Task<object> ReadTextAsync(JsonElement args)
    {
        var path = RequiredString(args, "path");
        var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));

        if (!File.Exists(fullPath))
        {
            throw new BridgeToolException("file_not_found", $"File does not exist: {fullPath}");
        }

        var maxChars = Math.Clamp(OptionalInt(args, "max_chars", 200_000), 1, 1_000_000);

        using var reader = new StreamReader(fullPath, detectEncodingFromByteOrderMarks: true);
        var buffer = new char[maxChars + 1];
        var count = await reader.ReadBlockAsync(buffer, 0, buffer.Length);
        var truncated = count > maxChars;
        var text = new string(buffer, 0, Math.Min(count, maxChars));

        return new
        {
            path = fullPath,
            text,
            truncated,
            maxChars
        };
    }

    private async Task<object?> ExecuteLocalIntentAsync(
        JsonElement args,
        CancellationToken cancellationToken)
    {
        if (_localIntentPlanner is null)
        {
            throw new BridgeToolException(
                "private_transport_unavailable",
                "The server-side local intent planner is not attached to this bridge session.");
        }

        var instruction = RequiredString(args, "instruction");
        var plan = await _localIntentPlanner(instruction, cancellationToken);

        if (string.Equals(plan.Tool, "local.intent", StringComparison.Ordinal))
        {
            throw new BridgeToolException(
                "private_transport_protocol",
                "The server-side planner returned a recursive local.intent action.");
        }

        if (!ToolDefinitionsByName.ContainsKey(plan.Tool))
        {
            throw new BridgeToolException(
                "private_transport_protocol",
                $"The server-side planner returned an unknown tool: {plan.Tool}");
        }

        var result = await ExecuteAsync(plan.Tool, plan.Args, cancellationToken);

        return new
        {
            instruction,
            plannedTool = plan.Tool,
            result,
            transport = new
            {
                probeId = plan.ProbeId,
                messageId = plan.MessageId,
                runId = plan.RunId,
                runCreatedAt = plan.RunCreatedAt,
                elapsedMs = plan.ElapsedMs
            }
        };
    }

    private static async Task<object> CopyFirstLineAsync(JsonElement args)
    {
        var sourcePath = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(
                RequiredString(args, "source_path")));
        var destinationRaw = RequiredString(args, "destination_path");
        var overwrite = OptionalBool(args, "overwrite", true);
        var createDirectories = OptionalBool(args, "create_directories", true);

        if (!File.Exists(sourcePath))
        {
            throw new BridgeToolException(
                "file_not_found",
                $"Source file does not exist: {sourcePath}");
        }

        var destinationPath = ResolveWritePath(
            destinationRaw,
            createDirectories);
        var existed = File.Exists(destinationPath);

        if (existed && !overwrite)
        {
            throw new BridgeToolException(
                "file_exists",
                $"Destination file already exists. Set overwrite=true to replace it: {destinationPath}");
        }

        var bytes = await File.ReadAllBytesAsync(sourcePath);
        var (text, sourceEncoding) = DecodeText(bytes);
        var breakIndex = text.IndexOfAny(['\r', '\n']);
        var firstLine = breakIndex >= 0
            ? text[..breakIndex]
            : text;

        var utf8 = new System.Text.UTF8Encoding(false);
        await WriteBytesAtomicAsync(
            destinationPath,
            utf8.GetBytes(firstLine),
            overwrite);

        var written = await File.ReadAllTextAsync(
            destinationPath,
            System.Text.Encoding.UTF8);

        if (!string.Equals(written, firstLine, StringComparison.Ordinal))
        {
            throw new BridgeToolException(
                "write_verify_failed",
                "Destination read-back does not match the source first line.");
        }

        return new
        {
            sourcePath,
            destinationPath,
            sourceEncoding,
            destinationEncoding = "utf-8",
            charsWritten = firstLine.Length,
            overwritten = existed,
            verified = true
        };
    }

    private static (string Text, string EncodingName) DecodeText(byte[] bytes)
    {
        if (bytes.Length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF)
        {
            return (
                System.Text.Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3),
                "utf-8-bom");
        }

        if (bytes.Length >= 2 &&
            bytes[0] == 0xFF &&
            bytes[1] == 0xFE)
        {
            return (
                System.Text.Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2),
                "utf-16le");
        }

        if (bytes.Length >= 2 &&
            bytes[0] == 0xFE &&
            bytes[1] == 0xFF)
        {
            return (
                System.Text.Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2),
                "utf-16be");
        }

        try
        {
            var strictUtf8 = new System.Text.UTF8Encoding(
                encoderShouldEmitUTF8Identifier: false,
                throwOnInvalidBytes: true);
            return (strictUtf8.GetString(bytes), "utf-8");
        }
        catch (System.Text.DecoderFallbackException)
        {
            System.Text.Encoding.RegisterProvider(
                System.Text.CodePagesEncodingProvider.Instance);
            var cp1251 = System.Text.Encoding.GetEncoding(
                1251,
                System.Text.EncoderFallback.ExceptionFallback,
                System.Text.DecoderFallback.ExceptionFallback);
            return (cp1251.GetString(bytes), "windows-1251");
        }
    }

    private static async Task<object> WriteTextAsync(JsonElement args)
    {
        var path = RequiredString(args, "path");
        var text = RequiredStringAllowEmpty(args, "text");
        var overwrite = OptionalBool(args, "overwrite", false);
        var createDirectories = OptionalBool(args, "create_directories", false);
        var fullPath = ResolveWritePath(path, createDirectories);
        var existed = File.Exists(fullPath);

        if (existed && !overwrite)
        {
            throw new BridgeToolException(
                "file_exists",
                $"File already exists. Set overwrite=true to replace it: {fullPath}");
        }

        var encoding = new System.Text.UTF8Encoding(false);
        var bytes = encoding.GetBytes(text);
        await WriteBytesAtomicAsync(fullPath, bytes, overwrite);

        return new
        {
            path = fullPath,
            charsWritten = text.Length,
            bytesWritten = bytes.Length,
            encoding = "utf-8",
            overwritten = existed
        };
    }

    private static async Task<object> AppendTextAsync(JsonElement args)
    {
        var path = RequiredString(args, "path");
        var text = RequiredStringAllowEmpty(args, "text");
        var createIfMissing = OptionalBool(args, "create_if_missing", false);
        var createDirectories = OptionalBool(args, "create_directories", false);
        var fullPath = ResolveWritePath(path, createDirectories);
        var existed = File.Exists(fullPath);

        if (!existed && !createIfMissing)
        {
            throw new BridgeToolException(
                "file_not_found",
                $"File does not exist. Set create_if_missing=true to create it: {fullPath}");
        }

        if (Directory.Exists(fullPath))
        {
            throw new BridgeToolException("path_is_directory", $"Path is a directory: {fullPath}");
        }

        var encoding = new System.Text.UTF8Encoding(false);
        await File.AppendAllTextAsync(fullPath, text, encoding);

        return new
        {
            path = fullPath,
            charsAppended = text.Length,
            bytesAppended = encoding.GetByteCount(text),
            created = !existed,
            encoding = "utf-8"
        };
    }

    private static async Task<object> WriteFileAsync(JsonElement args)
    {
        var path = RequiredString(args, "path");
        var content = RequiredStringAllowEmpty(args, "content");
        var encodingName = OptionalString(args, "encoding", "base64").Trim().ToLowerInvariant();
        var overwrite = OptionalBool(args, "overwrite", false);
        var createDirectories = OptionalBool(args, "create_directories", false);
        var fullPath = ResolveWritePath(path, createDirectories);
        var existed = File.Exists(fullPath);

        if (existed && !overwrite)
        {
            throw new BridgeToolException(
                "file_exists",
                $"File already exists. Set overwrite=true to replace it: {fullPath}");
        }

        byte[] bytes;
        try
        {
            bytes = encodingName switch
            {
                "base64" => Convert.FromBase64String(content),
                "utf8" or "utf-8" => new System.Text.UTF8Encoding(false).GetBytes(content),
                _ => throw new BridgeToolException(
                    "invalid_args",
                    "encoding must be either 'base64' or 'utf8'.")
            };
        }
        catch (FormatException)
        {
            throw new BridgeToolException("invalid_base64", "content is not valid Base64.");
        }

        if (bytes.Length > MaxWriteFileBytes)
        {
            throw new BridgeToolException(
                "file_too_large",
                $"Decoded file is {bytes.Length} bytes; maximum is {MaxWriteFileBytes} bytes.");
        }

        await WriteBytesAtomicAsync(fullPath, bytes, overwrite);

        return new
        {
            path = fullPath,
            bytesWritten = bytes.Length,
            sourceEncoding = encodingName,
            overwritten = existed,
            maxBytes = MaxWriteFileBytes
        };
    }

    private async Task<object> RunProcessAsync(
        JsonElement args,
        CancellationToken cancellationToken)
    {
        var file = RequiredString(args, "file");
        var arguments = OptionalStringArray(args, "arguments");
        var workingDirectoryRaw = OptionalString(args, "cwd", string.Empty);
        var timeoutMs = Math.Clamp(
            OptionalInt(args, "timeout_ms", DefaultProcessTimeoutMs),
            1_000,
            MaxProcessTimeoutMs);
        var maxOutputChars = Math.Clamp(
            OptionalInt(args, "max_output_chars", DefaultProcessOutputChars),
            1_000,
            MaxProcessOutputChars);

        string? workingDirectory = null;
        if (!string.IsNullOrWhiteSpace(workingDirectoryRaw))
        {
            workingDirectory = Path.GetFullPath(
                Environment.ExpandEnvironmentVariables(workingDirectoryRaw));

            if (!Directory.Exists(workingDirectory))
            {
                throw new BridgeToolException(
                    "directory_not_found",
                    $"Working directory does not exist: {workingDirectory}");
            }
        }

        var outcome = await _processes.RunAsync(
            new ProcessRunSpec(
                file,
                arguments,
                workingDirectory,
                timeoutMs,
                maxOutputChars),
            cancellationToken);

        return new
        {
            executionId = outcome.ExecutionId,
            file = outcome.File,
            arguments = outcome.Arguments,
            cwd = outcome.WorkingDirectory,
            exitCode = outcome.ExitCode,
            stdout = outcome.Stdout,
            stderr = outcome.Stderr,
            stdoutTruncated = outcome.StdoutTruncated,
            stderrTruncated = outcome.StderrTruncated,
            timedOut = outcome.TimedOut,
            stopped = outcome.Stopped,
            cancelled = outcome.Cancelled,
            elapsedMs = outcome.ElapsedMs,
            timeoutMs = outcome.TimeoutMs,
            maxOutputChars = outcome.MaxOutputChars
        };
    }

    private static string ResolveWritePath(string path, bool createDirectories)
    {
        var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));

        if (Directory.Exists(fullPath))
        {
            throw new BridgeToolException("path_is_directory", $"Path is a directory: {fullPath}");
        }

        var parent = Path.GetDirectoryName(fullPath);
        if (string.IsNullOrWhiteSpace(parent))
        {
            throw new BridgeToolException("invalid_path", $"Could not resolve parent directory: {fullPath}");
        }

        if (!Directory.Exists(parent))
        {
            if (!createDirectories)
            {
                throw new BridgeToolException(
                    "directory_not_found",
                    $"Parent directory does not exist. Set create_directories=true to create it: {parent}");
            }

            Directory.CreateDirectory(parent);
        }

        return fullPath;
    }

    private static async Task WriteBytesAtomicAsync(
        string fullPath,
        byte[] bytes,
        bool overwrite)
    {
        var parent = Path.GetDirectoryName(fullPath)!;
        var tempPath = Path.Combine(
            parent,
            $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.localbridge.tmp");

        try
        {
            await File.WriteAllBytesAsync(tempPath, bytes);
            File.Move(tempPath, fullPath, overwrite);
        }
        finally
        {
            if (File.Exists(tempPath))
            {
                try
                {
                    File.Delete(tempPath);
                }
                catch
                {
                    // Best-effort cleanup only.
                }
            }
        }
    }

    private static string[] OptionalStringArray(JsonElement args, string name)
    {
        if (args.ValueKind != JsonValueKind.Object ||
            !args.TryGetProperty(name, out var value))
        {
            return Array.Empty<string>();
        }

        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new BridgeToolException(
                "invalid_args",
                $"Argument '{name}' must be an array of strings.");
        }

        var items = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw new BridgeToolException(
                    "invalid_args",
                    $"Argument '{name}' must contain only strings.");
            }

            items.Add(item.GetString() ?? string.Empty);
        }

        return items.ToArray();
    }

    private static JsonElement OptionalObject(JsonElement args, string name)
    {
        if (args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty(name, out var value))
        {
            if (value.ValueKind is not JsonValueKind.Object and not JsonValueKind.Null)
            {
                throw new BridgeToolException(
                    "invalid_args",
                    $"Argument '{name}' must be a JSON object.");
            }

            return value.Clone();
        }

        using var empty = JsonDocument.Parse("{}");
        return empty.RootElement.Clone();
    }

    private static string RequiredStringAllowEmpty(JsonElement args, string name)
    {
        if (args.ValueKind != JsonValueKind.Object ||
            !args.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new BridgeToolException("invalid_args", $"Required string argument is missing: {name}");
        }

        return value.GetString() ?? string.Empty;
    }

    private static string OptionalString(JsonElement args, string name, string defaultValue)
    {
        if (args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty(name, out var value) &&
            value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? defaultValue;
        }

        return defaultValue;
    }

    private static bool OptionalBool(JsonElement args, string name, bool defaultValue)
    {
        if (args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty(name, out var value) &&
            value.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            return value.GetBoolean();
        }

        return defaultValue;
    }

    private static string RequiredString(JsonElement args, string name)
    {
        if (args.ValueKind != JsonValueKind.Object ||
            !args.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new BridgeToolException("invalid_args", $"Required string argument is missing: {name}");
        }

        return value.GetString()!;
    }

    private static int OptionalInt(JsonElement args, string name, int defaultValue)
    {
        if (args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty(name, out var value) &&
            value.TryGetInt32(out var parsed))
        {
            return parsed;
        }

        return defaultValue;
    }

    public void Dispose()
    {
        _mcp.Dispose();
        _processes.Dispose();
    }
}

public sealed class BridgeToolException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}