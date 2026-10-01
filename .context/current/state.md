# Current state

Updated: 2026-10-01 19:02 MSK

## Governance
- manager: `chatgpt-desktop-local-bridge-project-manager`
- manager generation: 4
- manager-state authority: `manager-state`
- product authority: `main@724a64b7f1ccc0ec92cd95fb511ecf1acb74ca95`
- execution status: ACTIVE / BRIDGE-M1 live validation

## Packaging/auth baseline
- preferred package: `dev-1d00606 / ChatGptDesktopLocalBridge-Setup.exe`
- installer SHA-256: `1ee7a76720ec9938dbdb59401200dcae79fb3e3a6d23380cf3d604f9e386260d`
- install scope: current user
- stable AppId supports in-place upgrade
- install directory: `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`
- persistent WebView2 UDF: `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`
- normal upgrade does not replace the WebView2 UDF

## Repository storage hygiene
- current Git tree contains no tracked blob over 500 KB at the verification point
- normal dev release publishes installer only
- automatic cleanup retains at most two installable dev prereleases
- portable-only prereleases/tags and redundant ZIP assets are deleted
- stable releases are not touched
- current Releases state: exactly one dev release, `dev-1d00606`, containing only Setup.exe
- no GitHub Actions artifact upload step is used

## BRIDGE-M1 live evidence
Owner pressed Diagnostics on `dev-977a504` and received:
`Diagnostics failed: Local Bridge adapter is not injected.`

Source analysis identified a probable early-document bootstrap defect involving `document.documentElement` availability. This remains a hypothesis until a patched installer passes live Diagnostics.

## Product baseline
- Windows WPF + WebView2 wrapper for `chatgpt.com`
- direct JS -> `window.chrome.webview.postMessage` -> C# bridge IPC
- permissions JSON and audit JSONL
- tools: `system.info`, `fs.list`, `fs.read_text`
- nonce-bound READY handshake exists in source but cannot yet be live-tested because adapter injection fails first

## Approved next architecture work
After closing the immediate adapter injection defect: generation detection, visible DOM selection, verified send, fail-closed DOM state, explicit bridge states, capability registry, bounded results, durable exactly-once execution, separate delivery state, and Windows Job Object STOP before shell/process capability.
