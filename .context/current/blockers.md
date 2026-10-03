# Current blockers and open risks

Updated: 2026-10-03 06:10 MSK

## UI-SHELL-R1 validation gate

The implementation stage 1–7 has passed CI but not yet the only evidence that can validate signed-in WebView behavior: Owner-side Windows testing.

The candidate must not supersede accepted baseline `0.2.8.0 / af6ac653` until the Owner verifies startup, loading/black-area behavior, already-loaded tab switching and background preload, ordinary downloads, custom context-menu open-in-tab without crash, Local Bridge restoration, theme/reset behavior, and updater placement/behavior.

The implementation is intentionally split into four commits so a regression can be isolated without another broad rewrite.

## Composition-control deployment failure
`WebView2CompositionControl` remains excluded from the recovery lineage. The earlier missing `Microsoft.Windows.SDK.NET` runtime dependency is unresolved and no new runtime proof exists.

## Context-menu COM boundary
Direct `CoreWebView2ContextMenuTarget.LinkUri` remains forbidden. Candidate `4c92f81` uses pre-captured adapter target state only; runtime timing still requires Owner validation.

## BRIDGE-M3 reconciliation
The exact `ea074e0` transport path is live-proven, while later `main` contains substantial M3 durability work. These lineages remain unreconciled.

## Result auto-submit intermittency
At least one process-run result was fully inserted into the ChatGPT composer but automatic submission failed. Later results delivered automatically.

## BRIDGE-M4 process containment
`process.run` still lacks Windows Job Object kill-on-close. Stronger bridge-owned process containment remains required before broad unattended process expansion.
