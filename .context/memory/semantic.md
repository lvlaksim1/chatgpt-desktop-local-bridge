# Semantic memory

## Architecture lessons admitted 2026-10-01

- The direct embedded-WebView architecture remains preferred: WebView2 already provides native IPC through `window.chrome.webview.postMessage`, so a browser extension + localhost service is unnecessary for the current product.
- Real ChatGPT DOM compatibility is a live integration boundary; compilation cannot prove selector correctness, generation detection, composer behavior, authentication UI, downloads, or actual submission.
- Exactly-once execution and exactly-once result delivery are separate reliability problems; durable request identity/recovery is required before mutating/process capability can be considered robust.
- Windows Job Objects with kill-on-close remain the preferred containment primitive for future bridge-owned process trees and emergency STOP.

## Local Bridge lessons admitted 2026-10-02

- Complete application behavior at source `ea074e0`, not merely one submit call, is the canonical live transport baseline. Same-day Owner proof establishes that later transport failures are application regressions.
- Filesystem mutation and local process execution can be layered onto the proven `ea074e0` transport while preserving a working request/result path.
- A generic structured `process.run` primitive is sufficient for initial Git/GitHub/PowerShell access; no dedicated GitHub implementation inside the bridge is currently needed.
- Result staging and result submission are distinct steps: a complete result can already be present in the composer even when automatic send confirmation fails.
- Interactive elapsed time is dominated by chat round trips, not local command execution. Safe dependent CLI work should be grouped into one bounded noninteractive stage where practical.
- Owner operating decision: future GitHub manipulation should normally use Local Bridge with local `git`, `gh`, and PowerShell. ChatGPT connector use is exceptional.

## Third-party licensing note

- `nwn900/ChatGPTDesktopApp` declares ISC.
- `mozg4D/chatgpt-local-agent` declares MIT.
- `mikhail494/chatgpt-local-hands` had no explicit repository license at review time; do not copy its code without later license verification.
