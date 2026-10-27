# MCP Probe — isolated local test

Minimal **read-only** official C# MCP SDK server. It does not change the
existing WPF bridge, require WebView2, access the user's files or execute
commands. It provides only `bridge_ping`.

## Build

```powershell
dotnet build tools/McpProbe/McpProbe.csproj -c Release
```

## Start with stdio

```powershell
dotnet tools/McpProbe/bin/Release/net8.0/McpProbe.dll
```

The process expects MCP JSON-RPC on stdin; do not type human commands.
Use an MCP client or the automated local smoke test below.

## Local protocol smoke test

```powershell
python tools/McpProbe/test_mcp_stdio.py
```

Expected:
- initialize succeeds;
- tools/list includes `bridge_ping`;
- tools/call returns `CHATGPT_DESKTOP_LOCAL_BRIDGE_MCP_PING_OK`.

## Remote integration

Do not expose this stdio server on the public internet.
Use the official Secure MCP Tunnel client with a private tunnel configured
in the matching OpenAI Platform organization and ChatGPT workspace.
Run the tunnel-client with `--mcp-command` pointing to this built process.
Use the UI to enter/obtain the tunnel ID and local secret without placing
API keys in Git, logs, PowerShell argument lists, or chat.

The local smoke test does NOT mean ChatGPT remote connectivity works;
that requires a separately verified tunnel and a real ChatGPT tool call.
