# Remote MCP E2E acceptance — 28.10.2026

**Status:** PASS — read-only `bridge_ping` from ordinary ChatGPT via our own custom MCP plugin, OpenAI Secure MCP Tunnel, and local Windows stdio MCP server.

## Verified observations

1. User created tunnel `tunnel_6ae12938ad8c819193f1fac63bfd47a0`, name `chatgpt-bridge-tunnel`, and registered `ChatGPT Desktop Local Bridge` as a ChatGPT custom MCP plugin.
2. Official tunnel-client v0.0.18 running on DOMKAT. Local agent process: `tunnel-client.exe`; child: `dotnet.exe`.
3. MCP probe `bridge_ping` registered in the actual ChatGPT plugin tool catalog as `mcp__ChatGPT_Desktop_Local_Bridge__bridge_ping`.
4. From the active ChatGPT conversation, direct MCP call `bridge_ping({})` returned exactly `CHATGPT_DESKTOP_LOCAL_BRIDGE_MCP_PING_OK`.
5. On Windows, the tunnel's local `/healthz` returned HTTP 200 `live`, and `/readyz` HTTP 200 `ready`. After the MCP invocation, `/readyz` still returned `ready`.
6. Local `runtime.log` on DOMKAT recorded `dispatcher forwarded command to MCP server` at 2026-10-28 02:22:18 +03:00, correlating with the call.
7. Only read-only tool `bridge_ping` is exposed. Nothing involving file mutation or process execution is currently authorized by this probe.

## Root cause of the first failed startup

The `tunnel-client` parser handles backslashes in Windows command strings as escape characters. Quoted backslash path `D:\...\McpProbe.dll` was malformed; the child exited with status 1. This was corrected to forward-slash path `D:/.../McpProbe.dll`. The next start and live MCP invocation passed.

## Secure credential handling

The runtime API key was entered locally, validated against the tunnel metadata endpoint and stored for future startups using user-scoped Windows DPAPI encryption at:
`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\McpProbe\runtime-key.dpapi`.

Raw API keys were neither included in GitHub nor returned to the ChatGPT conversation. The test profile is on D: at
`D:\test\chatgpt-bridge-mcp-probe\.tools\tunnel-profiles\local-bridge-probe.yaml`.

## Accepted scope and pending work

**Proven:** ChatGPT custom plugin -> OpenAI cloud tunnel -> locally running Windows MCP server -> tool result to same ChatGPT conversation, without DOM-based text protocol or scheduled task planner.

**Not yet proven:** read/write tools connected to the project's existing `ToolRouter`, permission `AUTO/ASK/DENY`, cancellation, durable request ledger integration, unattended Windows startup, app UI integration, recovery from disconnect/restart.

**Next engineering stage:** add read-only `bridge.system_info` and `bridge.list_files`, preferably by routing through existing `ToolRouter` in the production project rather than duplicating filesystem implementation in the probe. Exercise direct ChatGPT invocations and audit traces; then introduce write tools only with tested permission controls.

This record is the first verified remote MCP proof, not a claim that the overall Local Bridge migration is complete.
