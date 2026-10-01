# Project architecture

## DECISION — Product architecture

The current product has four primary layers:

1. **Windows shell:** WPF/.NET 8 desktop application.
2. **Chat surface:** WebView2 hosting `https://chatgpt.com/` with a persistent user-data profile.
3. **Web adapter:** injected JavaScript that observes completed assistant turns, parses exact Local Bridge envelopes, stages service messages, and exchanges native IPC through `window.chrome.webview.postMessage`.
4. **Native Local Bridge:** in-process C# host with session validation, permission policy, tool routing, result injection, and audit logging.

There is no localhost HTTP bridge in the current design.

## Protocol

Assistant-to-machine requests use `LOCAL_BRIDGE_REQUEST_V1`; machine-to-assistant results use `LOCAL_BRIDGE_RESULT_V1`. Initialization uses a fresh per-initialization session nonce and a nonce-bound READY handshake.

## Persistent paths

- WebView2 profile: `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`
- user permissions: `%APPDATA%\ChatGptDesktopLocalBridge\permissions.json`
- audit logs: `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\logs\bridge-YYYYMMDD.jsonl`

## Authority topology

Product authority is `main`.
Durable Project Manager authority is `manager-state`.
The `main` branch contains only a discovery redirect for Context Capsule.
