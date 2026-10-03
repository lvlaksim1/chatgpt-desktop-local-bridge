# Latest handoff

Updated: 2026-10-03 05:49 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 16.
Product authority: `main`.
Manager-state authority: `manager-state`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI recovery baseline: `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053`.

## Owner rollback directive
The Owner rejected the 0.2.9/0.2.10 UI lineage and explicitly directed continued development from 0.2.8, described as the last acceptable version. Live repository reconciliation confirms `dev/ui-shell-v5` now points exactly to `af6ac653`.

The 0.2.9 prerelease/tag `ui-shell-71fd69f` and 0.2.10 hotfix prerelease/tag `ui-shell-24ebaef` were removed from the GitHub release channel. Their commits remain historical evidence and are not continuation baselines.

## Confirmed failure evidence
Two independent crash causes are now durable knowledge:
1. `WebView2CompositionControl` caused startup `FileNotFoundException` for `Microsoft.Windows.SDK.NET, Version=10.0.17763.10` during `TryInitializeD3DImage()/OnApplyTemplate()`.
2. Direct `CoreWebView2ContextMenuTarget.LinkUri` access caused `COMException 0x8000000E` and process termination.

Recovery constraints:
- keep ordinary `WebView2`;
- do not directly read `ContextMenuTarget.LinkUri`;
- optional UI enhancements must fail closed;
- preserve bridge restore, background preloading, profile/session continuity, and updater continuity from 0.2.8.

## UI recovery backlog
Proceed incrementally with Owner validation after each fundamental WebView/UI change:
- loading flash and black/unused browser area;
- switching already-loaded tabs without flash;
- preserve background tab preloading;
- native download behavior for ordinary links;
- safe explicit “Открыть в новой вкладке”;
- crash containment for optional UI handlers;
- broader unified ChatGPT theme;
- explicit theme reset;
- full Setup only in Settings → Updates, ordinary update path delta-focused.

After the UI slice: Diagnostics filters/copy/expand/export, result-delivery diagnostics, transport research away from composer dependency, fine-grained ASK permissions, local-tool expansion, E2E/installer/multi-monitor/DPI hardening, app icon, and Russian UI cleanup.

## Existing bridge commitments
BRIDGE-M3 reconciliation with the proven `ea074e0` transport remains open.
BRIDGE-M4 write/process tools are live-proven on the development lineage.
One intermittent staged-but-not-auto-submitted result remains an open transport weakness.
Windows Job Object or equivalent process containment remains required before broad unattended process expansion.

## Operating method
Use one narrowly scoped fundamental UI change per prerelease where practical. CI proves build/package integrity; Owner-side Windows testing proves live ChatGPT/WebView behavior. Revert a failed step to the last accepted baseline rather than accumulating multiple unverified WebView changes.
