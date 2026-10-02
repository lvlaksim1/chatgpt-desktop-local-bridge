using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed class ToolRouter
{
    public async Task<object?> ExecuteAsync(string tool, JsonElement args)
    {
        return tool switch
        {
            "system.info" => GetSystemInfo(),
            "fs.list" => ListDirectory(args),
            "fs.read_text" => await ReadTextAsync(args),
            "fs.write_text" => await WriteTextAsync(args),
            "fs.append_text" => await AppendTextAsync(args),
            "fs.write_file" => await WriteFileAsync(args),
            "process.run" => await RunProcessAsync(args),
            _ => throw new BridgeToolException("unknown_tool", $"Unknown local tool: {tool}")
        };
    }

    public static string GetCapability(string tool) => tool switch
    {
        "system.info" => "system.info",
        "fs.list" => "fs.list",
        "fs.read_text" => "fs.read_text",
        "fs.write_text" => "fs.write_text",
        "fs.append_text" => "fs.write_text",
        "fs.write_file" => "fs.write_text",
        "process.run" => "process.start",
        _ => tool
    };

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

        var maxChars = OptionalInt(args, "max_chars", 200_000);
        maxChars = Math.Clamp(maxChars, 1, 1_000_000);

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

    private const int MaxWriteFileBytes = 1_048_576;

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

        var bytes = new System.Text.UTF8Encoding(false).GetBytes(text);
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

    private const int DefaultProcessTimeoutMs = 120_000;
    private const int MaxProcessTimeoutMs = 900_000;
    private const int DefaultProcessOutputChars = 200_000;
    private const int MaxProcessOutputChars = 1_000_000;

    private static async Task<object> RunProcessAsync(JsonElement args)
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

        var startInfo = new ProcessStartInfo
        {
            FileName = Environment.ExpandEnvironmentVariables(file),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = true
        };

        if (workingDirectory is not null)
        {
            startInfo.WorkingDirectory = workingDirectory;
        }

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        var stopwatch = Stopwatch.StartNew();

        try
        {
            if (!process.Start())
            {
                throw new BridgeToolException(
                    "process_start_failed",
                    $"Could not start process: {file}");
            }
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "process_start_failed",
                $"Could not start process '{file}': {ex.Message}");
        }

        var stdoutTask = ReadCappedAsync(process.StandardOutput, maxOutputChars);
        var stderrTask = ReadCappedAsync(process.StandardError, maxOutputChars);

        var timedOut = false;
        using (var timeout = new CancellationTokenSource(timeoutMs))
        {
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                timedOut = true;
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch
                {
                    // Best effort. WaitForExitAsync below still gives the process a chance to report exit.
                }

                try
                {
                    await process.WaitForExitAsync();
                }
                catch
                {
                    // Preserve the timeout result even if the process cannot be observed after termination.
                }
            }
        }

        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        stopwatch.Stop();

        int? exitCode = null;
        if (process.HasExited)
        {
            exitCode = process.ExitCode;
        }

        return new
        {
            file,
            arguments,
            cwd = workingDirectory,
            exitCode,
            stdout = stdout.Text,
            stderr = stderr.Text,
            stdoutTruncated = stdout.Truncated,
            stderrTruncated = stderr.Truncated,
            timedOut,
            elapsedMs = stopwatch.ElapsedMilliseconds,
            timeoutMs,
            maxOutputChars
        };
    }

    private static async Task<CappedTextResult> ReadCappedAsync(StreamReader reader, int maxChars)
    {
        var builder = new StringBuilder(Math.Min(maxChars, 16_384));
        var buffer = new char[8_192];
        var truncated = false;

        while (true)
        {
            var read = await reader.ReadAsync(buffer, 0, buffer.Length);
            if (read <= 0)
            {
                break;
            }

            var remaining = maxChars - builder.Length;
            if (remaining > 0)
            {
                builder.Append(buffer, 0, Math.Min(read, remaining));
            }

            if (read > remaining)
            {
                truncated = true;
            }
        }

        return new CappedTextResult(builder.ToString(), truncated);
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

    private sealed record CappedTextResult(string Text, bool Truncated);

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

    private static async Task WriteBytesAtomicAsync(string fullPath, byte[] bytes, bool overwrite)
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
                    // Best-effort cleanup. The target operation has already completed or failed.
                }
            }
        }
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
}

public sealed class BridgeToolException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
