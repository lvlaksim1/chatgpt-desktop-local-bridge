using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed class McpConfiguration
{
    public string Schema { get; set; } = "chatgpt-desktop-local-bridge-mcp-v1";
    public List<McpServerConfiguration> Servers { get; set; } = [];
}

public sealed class McpServerConfiguration
{
    public string Id { get; set; } = string.Empty;
    public bool Enabled { get; set; } = true;
    public string Command { get; set; } = string.Empty;
    public List<string> Arguments { get; set; } = [];
    public string? WorkingDirectory { get; set; }
    public Dictionary<string, string?> Environment { get; set; } =
        new(StringComparer.OrdinalIgnoreCase);
    public List<string>? AllowedTools { get; set; }
}

public sealed class McpManager : IDisposable
{
    private static readonly Regex ServerIdPattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, McpClient> _clients =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IReadOnlyList<McpClientTool>> _toolsCache =
        new(StringComparer.OrdinalIgnoreCase);

    public static string GetUserConfigurationPath()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ChatGptDesktopLocalBridge");
        return Path.Combine(directory, "mcp.json");
    }

    public static string EnsureUserConfiguration()
    {
        var userPath = GetUserConfigurationPath();
        var directory = Path.GetDirectoryName(userPath)!;
        Directory.CreateDirectory(directory);

        if (!File.Exists(userPath))
        {
            var defaultPath = Path.Combine(
                AppContext.BaseDirectory,
                "Config",
                "mcp.default.json");

            if (File.Exists(defaultPath))
            {
                File.Copy(defaultPath, userPath);
            }
            else
            {
                File.WriteAllText(
                    userPath,
                    JsonSerializer.Serialize(
                        new McpConfiguration(),
                        new JsonSerializerOptions { WriteIndented = true }));
            }
        }

        return userPath;
    }

    public async Task<object> ListServersAsync(
        CancellationToken cancellationToken = default)
    {
        var config = LoadConfiguration();
        var servers = config.Servers
            .OrderBy(server => server.Id, StringComparer.OrdinalIgnoreCase)
            .Select(server => new
            {
                server.Id,
                server.Enabled,
                server.Command,
                arguments = server.Arguments,
                cwd = server.WorkingDirectory,
                allowedTools = server.AllowedTools,
                explicitEnvironmentVariables = server.Environment.Keys
                    .OrderBy(key => key, StringComparer.OrdinalIgnoreCase)
                    .ToArray()
            })
            .ToArray();

        await Task.CompletedTask;
        return new
        {
            configurationPath = GetUserConfigurationPath(),
            servers
        };
    }

    public async Task<object> ListToolsAsync(
        string serverId,
        bool forceRefresh,
        CancellationToken cancellationToken = default)
    {
        var config = LoadConfiguration();
        var server = GetEnabledServer(config, serverId);
        var tools = await GetToolsAsync(server, forceRefresh, cancellationToken);

        return new
        {
            server = server.Id,
            tools = tools.Select(tool => new
            {
                tool.Name,
                tool.Description,
                inputSchema = tool.JsonSchema
            }).ToArray()
        };
    }

    public async Task<object> CallAsync(
        string serverId,
        string toolName,
        JsonElement arguments,
        int timeoutMs,
        CancellationToken cancellationToken = default)
    {
        var config = LoadConfiguration();
        var server = GetEnabledServer(config, serverId);

        var tools = await GetToolsAsync(server, forceRefresh: false, cancellationToken);
        var tool = tools.FirstOrDefault(
            candidate => string.Equals(candidate.Name, toolName, StringComparison.Ordinal));

        if (tool is null)
        {
            throw new BridgeToolException(
                "mcp_tool_not_found",
                $"MCP server '{server.Id}' does not expose allowed tool '{toolName}'.");
        }

        var values = JsonObjectToDictionary(arguments);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeoutMs);

        try
        {
            var result = await tool.CallAsync(
                values,
                cancellationToken: timeoutCts.Token);

            return new
            {
                server = server.Id,
                tool = tool.Name,
                isError = result.IsError,
                content = result.Content,
                structuredContent = result.StructuredContent
            };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new BridgeToolException(
                "mcp_timeout",
                $"MCP tool '{server.Id}/{toolName}' exceeded the {timeoutMs} ms timeout.");
        }
        catch (OperationCanceledException)
        {
            throw new BridgeToolException(
                "mcp_cancelled",
                $"MCP tool '{server.Id}/{toolName}' was cancelled.");
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "mcp_call_failed",
                $"MCP tool '{server.Id}/{toolName}' failed: {ex.Message}");
        }
    }

    public void Dispose()
    {
        _gate.Wait();
        try
        {
            foreach (var client in _clients.Values)
            {
                try
                {
                    client.DisposeAsync().AsTask().GetAwaiter().GetResult();
                }
                catch
                {
                    // Best-effort shutdown of optional external MCP servers.
                }
            }

            _clients.Clear();
            _toolsCache.Clear();
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }

    private async Task<IReadOnlyList<McpClientTool>> GetToolsAsync(
        McpServerConfiguration server,
        bool forceRefresh,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (!forceRefresh &&
                _toolsCache.TryGetValue(server.Id, out var cached))
            {
                return cached;
            }

            var client = await GetOrCreateClientUnderGateAsync(server, cancellationToken);
            IList<McpClientTool> discovered;
            try
            {
                discovered = await client.ListToolsAsync(
                    cancellationToken: cancellationToken);
            }
            catch (Exception ex)
            {
                await DisposeClientUnderGateAsync(server.Id);
                throw new BridgeToolException(
                    "mcp_list_tools_failed",
                    $"Could not list tools from MCP server '{server.Id}': {ex.Message}");
            }

            IReadOnlyList<McpClientTool> filtered = server.AllowedTools is { Count: > 0 }
                ? discovered
                    .Where(tool => server.AllowedTools.Contains(tool.Name, StringComparer.Ordinal))
                    .ToArray()
                : discovered.ToArray();

            _toolsCache[server.Id] = filtered;
            return filtered;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<McpClient> GetOrCreateClientUnderGateAsync(
        McpServerConfiguration server,
        CancellationToken cancellationToken)
    {
        if (_clients.TryGetValue(server.Id, out var existing))
        {
            return existing;
        }

        var environment = StdioClientTransportOptions.GetDefaultEnvironmentVariables();
        foreach (var pair in server.Environment)
        {
            environment[pair.Key] = pair.Value;
        }

        var transport = new StdioClientTransport(
            new StdioClientTransportOptions
            {
                Name = "local-bridge-" + server.Id,
                Command = server.Command,
                Arguments = server.Arguments,
                WorkingDirectory = ResolveWorkingDirectory(server.WorkingDirectory),
                InheritEnvironmentVariables = false,
                EnvironmentVariables = environment
            });

        try
        {
            var client = await McpClient.CreateAsync(
                transport,
                cancellationToken: cancellationToken);
            _clients[server.Id] = client;
            return client;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "mcp_connect_failed",
                $"Could not connect to MCP server '{server.Id}': {ex.Message}");
        }
    }

    private async Task DisposeClientUnderGateAsync(string serverId)
    {
        if (_clients.Remove(serverId, out var client))
        {
            try
            {
                await client.DisposeAsync();
            }
            catch
            {
                // Connection is already considered unusable.
            }
        }

        _toolsCache.Remove(serverId);
    }

    private static string? ResolveWorkingDirectory(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var path = Path.GetFullPath(Environment.ExpandEnvironmentVariables(value));
        if (!Directory.Exists(path))
        {
            throw new BridgeToolException(
                "mcp_working_directory_not_found",
                $"MCP working directory does not exist: {path}");
        }

        return path;
    }

    private static McpConfiguration LoadConfiguration()
    {
        var path = EnsureUserConfiguration();

        try
        {
            var config = JsonSerializer.Deserialize<McpConfiguration>(
                             File.ReadAllText(path),
                             new JsonSerializerOptions
                             {
                                 PropertyNameCaseInsensitive = true
                             })
                         ?? throw new InvalidOperationException("Configuration is empty.");

            if (!string.Equals(
                    config.Schema,
                    "chatgpt-desktop-local-bridge-mcp-v1",
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"Unsupported MCP configuration schema: {config.Schema}");
            }

            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var server in config.Servers)
            {
                if (!ServerIdPattern.IsMatch(server.Id))
                {
                    throw new InvalidOperationException(
                        $"Invalid MCP server id '{server.Id}'.");
                }

                if (!ids.Add(server.Id))
                {
                    throw new InvalidOperationException(
                        $"Duplicate MCP server id '{server.Id}'.");
                }

                if (string.IsNullOrWhiteSpace(server.Command))
                {
                    throw new InvalidOperationException(
                        $"MCP server '{server.Id}' has no command.");
                }
            }

            return config;
        }
        catch (BridgeToolException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new BridgeToolException(
                "mcp_config_invalid",
                $"MCP configuration is invalid: {ex.Message}");
        }
    }

    private static McpServerConfiguration GetEnabledServer(
        McpConfiguration config,
        string serverId)
    {
        var server = config.Servers.FirstOrDefault(
            candidate => string.Equals(
                candidate.Id,
                serverId,
                StringComparison.OrdinalIgnoreCase));

        if (server is null)
        {
            throw new BridgeToolException(
                "mcp_server_not_found",
                $"MCP server is not configured: {serverId}");
        }

        if (!server.Enabled)
        {
            throw new BridgeToolException(
                "mcp_server_disabled",
                $"MCP server is disabled: {serverId}");
        }

        return server;
    }

    private static IReadOnlyDictionary<string, object?>? JsonObjectToDictionary(
        JsonElement element)
    {
        if (element.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return null;
        }

        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new BridgeToolException(
                "invalid_args",
                "MCP tool arguments must be a JSON object.");
        }

        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            result[property.Name] = property.Value.Clone();
        }

        return result;
    }
}