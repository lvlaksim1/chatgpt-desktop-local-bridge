# Current blockers and open risks

Updated: 2026-10-03 05:49 MSK

## UI-SHELL-R1

0.2.9/0.2.10 are not acceptable continuation bases. Development must branch conceptually and operationally from `0.2.8.0` / `af6ac653`.

### Composition-control deployment failure
Owner-side Windows event logs proved that `WebView2CompositionControl` can crash startup because the deployed package lacks `Microsoft.Windows.SDK.NET, Version=10.0.17763.10`. Do not reintroduce this control in the recovery lineage without independently proving its full deployment dependency chain on the Owner system.

### Context-menu COM crash
Direct `CoreWebView2ContextMenuTarget.LinkUri` access has produced unhandled `COMException 0x8000000E`. Custom context-menu target resolution must avoid this call and fail closed if no safe target is available.

### Runtime-only UI evidence
CI cannot prove signed-in ChatGPT/WebView rendering, download behavior, tab-switch visual stability, context-menu timing, or theme coverage. Every fundamental UI change needs Owner-side validation before becoming the next baseline.

### Existing UI backlog
Open user-visible issues include initial ChatGPT render flash, flash when switching loaded tabs, black/unused browser area, download-link behavior, safe custom open-in-tab, incomplete theme recoloring, missing explicit theme reset, and full Setup placement.

## BRIDGE-M3 reconciliation
The exact `ea074e0` transport path is live-proven, while later `main` contains substantial M3 durability work. These lineages are not yet reconciled. Do not overwrite M3 durability wholesale and do not reintroduce the post-`ea074e0` transport regression.

## Result auto-submit intermittency
At least one process-run result (`gh --version`) was fully inserted into the ChatGPT composer but automatic submission failed, requiring manual send. Later results delivered automatically. This is a transport/confirmation weakness, not a local process execution failure.

## BRIDGE-M4 process containment
`process.run` is intentionally live and authorized via the existing process capability, giving the bridge broad execution power under the current user account. It uses bounded timeout/output and kills the process tree on timeout, but does not yet use a Windows Job Object with kill-on-close. Before broad unattended shell/process expansion, stronger bridge-owned process containment remains required.

## Permission semantics
Because `process.run` can directly invoke ordinary executables such as PowerShell, process-execution permission is the effective gate for such use. Keep this explicit in future permission UX/design.

## Interactive latency
Local commands complete quickly; multiple ChatGPT request/result turns dominate wall-clock latency. Batch logically related noninteractive commands inside one bounded process stage where safe.
