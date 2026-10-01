# Current state

Updated: 2026-10-01 18:15 MSK

## Governance
- manager: `chatgpt-desktop-local-bridge-project-manager`
- manager generation: 1
- manager-state authority: `manager-state`
- product authority: `main@977a504be19e2d21cb3c524275b003b9a6db7592`
- execution status: ACTIVE / BRIDGE-M1 live validation

## Product baseline
- Windows WPF + WebView2 wrapper for `chatgpt.com`
- direct JS -> `window.chrome.webview.postMessage` -> C# bridge IPC
- persistent WebView2 profile
- permissions JSON and audit JSONL
- tools: `system.info`, `fs.list`, `fs.read_text`
- nonce-bound READY handshake
- self-contained development release `dev-977a504`

## Verification baseline
Windows CI for the current development release is successful. Server-side CI does not prove signed-in ChatGPT DOM/runtime behavior.

## Active external evidence gate
The Owner is installing/testing `dev-977a504`.
Required first evidence: Diagnostics result, then confirmed `Bridge ready`, then known-file `fs.read_text` round trip.

## Approved next architecture work
After or in response to live evidence: generation detection, visible DOM selection, verified send, fail-closed DOM state, explicit bridge states, capability registry, bounded results, durable exactly-once execution, separate delivery state, and Windows Job Object STOP before shell/process capability.
