# Current state

Updated: 2026-10-03 05:49 MSK

- manager generation: 16
- product authority: `main`
- current verified authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- manager-state authority: `manager-state`
- canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`
- BRIDGE-M1: CLOSED
- BRIDGE-M2: CLOSED
- BRIDGE-M3: ACTIVE; durable foundation substantially implemented, reconciliation with proven transport baseline still pending
- BRIDGE-M4: ACTIVE; first mutation/process slice live-proven on an `ea074e0`-derived development lineage
- UI-SHELL-R1: ACTIVE
- accepted UI-shell baseline: `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053`
- live repository check: `dev/ui-shell-v5` currently points exactly to `af6ac65306d5e91b84c48bb44fb7bc37da930053`
- Owner directive: 0.2.8 was the last acceptable version; continue UI development from it
- rejected UI lineages: 0.2.9 / `71fd69f3b38660b5ec58c21ffdbaf94c804b99dc` and 0.2.10 hotfix / `24ebaef3efb882366fbb5c620df80c2c06527621`
- the rejected 0.2.9/0.2.10 prereleases and tags were removed from the GitHub release channel; commits remain historical evidence
- confirmed 0.2.9 startup crash: `WebView2CompositionControl` dependency failure for `Microsoft.Windows.SDK.NET, Version=10.0.17763.10`
- confirmed context-menu crash: direct `CoreWebView2ContextMenuTarget.LinkUri` access can throw COM `0x8000000E`
- current UI rule: ordinary `WebView2` only for recovery; no direct `ContextMenuTarget.LinkUri`; optional UI enhancements must fail closed
- working behaviors to preserve from 0.2.8: Local Bridge restoration after load, background tab preloading, WebView profile/session continuity, updater continuity
- filesystem mutation tools `fs.write_text`, `fs.append_text`, `fs.write_file`: implemented in dev lineage
- `fs.append_text(D:/test/file.txt)`: live PASS
- `process.run`: implemented and live PASS
- local Git/GitHub CLI/GitHub auth/remote repo query: live PASS
- result auto-send still has one observed intermittent staged-but-not-auto-submitted failure
- current work priority: incremental UI recovery from 0.2.8 with Owner-side validation after each fundamental WebView/UI change, while preserving bridge behavior and the longer-term M3/M4 commitments
