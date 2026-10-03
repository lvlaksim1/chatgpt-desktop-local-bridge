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

## UI shell lessons admitted 2026-10-03

- `0.2.8.0` / `af6ac653` is the Owner-accepted recovery baseline after the 0.2.9/0.2.10 UI regression sequence.
- A compile-successful `WebView2CompositionControl` substitution is not deployment-safe by inference. On the Owner's Windows 10 system it triggered a startup `FileNotFoundException` for `Microsoft.Windows.SDK.NET, Version=10.0.17763.10`.
- `CoreWebView2ContextMenuTarget.LinkUri` has a timing-sensitive COM boundary: direct access produced `0x8000000E` and terminated the application. Context-link resolution must not depend on that property.
- Optional WebView UI enhancements must be isolated from application survival: context menu, theming, and link helpers should fail closed rather than terminate the WPF process.
- WebView visual correctness is a live-runtime property. CI cannot validate flashes, black surfaces, signed-in downloads, dynamic ChatGPT theme coverage, or context-menu timing.
- When several foundational WebView behaviors change in one release, a runtime regression becomes expensive to isolate. The recovery workflow should advance through narrowly scoped prereleases, promoting only Owner-validated baselines.
- A rejected release may still contain useful design ideas, but it is evidence, not a source branch to merge wholesale into the accepted baseline.

## Third-party licensing note

- `nwn900/ChatGPTDesktopApp` declares ISC.
- `mozg4D/chatgpt-local-agent` declares MIT.
- `mikhail494/chatgpt-local-hands` had no explicit repository license at review time; do not copy its code without later license verification.

## UI recovery candidate admitted 2026-10-03

- A page-owned fixed paint shield inside ordinary WebView2 is the current recovery strategy for masking navigation and tab-reveal paint transitions while avoiding the deployment failure of the CompositionControl experiment. It is implemented and CI-proven but not yet Owner-runtime-proven.
- Keeping initialized WebViews warm while switching only their parent containers is the current tab-preload strategy. Hidden ready tabs are armed with an internal switch shield before their next reveal.
- Native link/download semantics and custom app-tab navigation are intentionally separated: normal WebView behavior is left unintercepted, while explicit app-tab opening depends on a pre-captured DOM target.
- The recovery stage was committed in isolated slices before the release commit so runtime failures can be mapped back to a narrow change set.
