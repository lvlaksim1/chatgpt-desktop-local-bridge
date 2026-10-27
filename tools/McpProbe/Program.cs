using System.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Server;

// Read-only proof-of-connection. Do not print anything to stdout except MCP JSON-RPC.
var builder = Host.CreateApplicationBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole(options =>
{
    options.LogToStandardErrorThreshold = LogLevel.Trace;
});
builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithToolsFromAssembly();

await builder.Build().RunAsync();

[McpServerToolType]
public static class BridgeProbeTools
{
    [McpServerTool]
    [Description("Read-only connectivity test for chatgpt-desktop-local-bridge. Returns a fixed marker; does not access user files or execute commands.")]
    public static string bridge_ping() => "CHATGPT_DESKTOP_LOCAL_BRIDGE_MCP_PING_OK";
}
