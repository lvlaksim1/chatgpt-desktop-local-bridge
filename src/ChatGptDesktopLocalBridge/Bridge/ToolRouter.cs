using System.Runtime.InteropServices;
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
            _ => throw new BridgeToolException("unknown_tool", $"Unknown local tool: {tool}")
        };
    }

    public static string GetCapability(string tool) =>
        BridgeCapabilityRegistry.Resolve(tool).Capability;

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
