# Current blockers and open risks

Updated: 2026-10-01 18:50 MSK

## Immediate BRIDGE-M1 blocker
Live Diagnostics reports `Local Bridge adapter is not injected`.

Current source-level hypothesis: `AddScriptToExecuteOnDocumentCreatedAsync` executes the adapter early enough that `document.documentElement` may still be null; the immediate `MutationObserver.observe(document.documentElement, ...)` can therefore terminate the script before `window.__localBridge` is assigned.

This hypothesis is not yet accepted as root cause. It requires a patched build plus live Diagnostics.

## Authentication continuity
No upgrade blocker is known. Authentication continuity is intentionally based on the dedicated WebView2 User Data Folder outside the install directory. Direct Yandex Browser session-cookie/profile cloning is not part of the selected path because it lacks a robust cross-browser contract.

## Reliability debt before mutating tools
Current request deduplication is process-memory-only. It is adequate for the read-only MVP test but not sufficient for destructive, write, shell, or process actions across restart/crash boundaries.

## Process-control debt
There is not yet a Windows Job Object containment/emergency-STOP layer. Shell/process capabilities must not be treated as production-ready before that foundation exists.

## Packaging
Installer compilation and development prerelease publication are successful.
