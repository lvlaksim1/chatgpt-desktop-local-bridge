# Latest handoff

Updated: 2026-10-03 06:10 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 17.
Product authority: `main`.
Manager-state authority: `manager-state`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI runtime baseline: `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053`.
Current UI validation candidate: `ui-shell-4c92f81` / `4c92f81d46b77f964b8e99fe25439058b9b835a1`.

## UI-SHELL-R1 stage 1–7 implementation

The Owner directed execution of the first UI recovery stage from the clean 0.2.8 baseline and requested repository work through the standard GitHub connector.

Isolated commits:
- `f30424d` — page-owned paint shield, native WebView background matching, warm parent-only tab switching, preload preservation;
- `0ff4286b` — native link/download path restored, `NewWindowRequested` interception removed, safe adapter-cached context target;
- `ee6ce6e` — broader unified theme and explicit reset;
- `4c92f81` — delta-only top updater, full Setup moved to Settings → Updates, release trigger.

CI run `37092162098` completed successfully.
Prerelease `ui-shell-4c92f81` was published (workflow version `0.2.15.0`).

Delta from accepted 0.2.8 tag:
- `ChatGptDesktopLocalBridge-Update-from-ui-shell-af6ac65.exe`
- SHA-256 `a7dafb406b6af3bc45c04f5ff889518fd52b97ba8bb229ae6f6a3f96cffbb618`
- size 2,264,856 bytes

Full Setup:
- `ChatGptDesktopLocalBridge-ui-shell-Setup.exe`
- SHA-256 `5a01b0a0609d91ef44e8356ab982f1dda3835201d18b8fc6b37252a45fceb59f`
- size 51,494,899 bytes

## Validation status

CI/build/package: PASS.
Owner-side signed-in Windows runtime: PENDING.

Do not call this candidate accepted and do not supersede `af6ac653` until the Owner validates startup, rendering, tab switching, downloads, context menu, bridge restoration, theme/reset, and updater UX.

If a regression is found, use the isolated commit stack to repair the narrow slice rather than adding another broad WebView rewrite.

## Existing bridge commitments

BRIDGE-M3 reconciliation with `ea074e0` remains open.
BRIDGE-M4 write/process tools remain live-proven.
Intermittent result auto-submit remains open.
Windows Job Object/equivalent containment remains required before broad unattended process expansion.
