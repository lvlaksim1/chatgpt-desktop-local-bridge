# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority remains `main`; current known authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
3. Manager-state authority: `manager-state`.
4. BRIDGE-M1 and BRIDGE-M2 remain CLOSED. Canonical live transport baseline is source `ea074e06bd4e959106f49f57cad1ac731597dac3`.
5. BRIDGE-M3 durability work is substantially implemented on `main`, but reconciliation with the proven `ea074e0` transport behavior remains incomplete.
6. Same-day Owner testing proved exact `ea074e0` still completes the full `fs.read_text(C:/Windows/win.ini)` round trip in the current ChatGPT environment. Later transport failure is therefore a post-`ea074e0` application regression.
7. BRIDGE-M4 has started on an `ea074e0`-derived development lineage.
8. Filesystem mutation is live-proven:
   - branch `m4-write-tools-ea074e0`;
   - commits `c13781814ade651ee6b7d51f37a4b37ad997491b`, `826674c158df8ad868ec85823adbc2b38bb1653d`;
   - release workflow commit `38c2aca554268a07343b8e1a6c805e787b3971f9`;
   - prerelease `dev-ea074e0-write-tools`;
   - tools `fs.write_text`, `fs.append_text`, `fs.write_file`.
9. Owner-side live proof: `fs.append_text` appended `тестовый ответ` to `D:/test/file.txt` and returned `ok:true`.
10. Local process execution is live-proven:
   - branch `m4-process-run-write-tools`;
   - commits `a2c00c7619506c5aa0e98a523fc4b14ad255d141`, `ef2ac99a73cdc3c9a8fba8965d3a6ee9714e2753`;
   - release workflow commit `cdb78c9d5f1a230d012f26fca1e391be5c5c23f9`;
   - prerelease `dev-process-run`;
   - tool `process.run`.
11. `process.run` uses structured executable/arguments, optional cwd, bounded timeout/output, redirected stdout/stderr, no stdin, and kills the process tree on timeout. It reuses `process.start`.
12. Live CLI proof through Local Bridge succeeded: Git `2.55.0.windows.5`; GitHub CLI `2.98.0`; `gh auth status` exit 0 for active account `lvlaksim1`; `gh repo view lvlaksim1/chatgpt-desktop-local-bridge` exit 0 and reports default branch `main`.
13. Owner directive: future GitHub manipulation should normally use Local Bridge + local `git`/`gh`/PowerShell. ChatGPT GitHub connector use is exceptional and explicit.
14. Result transport still has an intermittent auto-submit weakness: the `gh --version` result was fully staged but required manual Send; later results auto-delivered.
15. One bridge machine request currently consumes one assistant turn. For multi-command work, prefer one bounded noninteractive process stage when safe.
16. Full current proven installer for the M4 process lineage: `ChatGptDesktopLocalBridge-process-run-Setup.exe`, prerelease `dev-process-run`, SHA-256 `ceec3c9c0204624979ee344b7a26a59821247618bc43645c9493f4dfbcf35d60`.
17. Incremental updater from write-tools: `ChatGptDesktopLocalBridge-Update-from-dev-ea074e0-write-tools.exe`, SHA-256 `03fde14068ca7159ed8be3c7f3b9d6b8d861f9cff58b5ae20bca82cf35d61fd6`.
18. Owner-side UI validation on 2026-10-03 established `0.2.8.0` / commit `af6ac65306d5e91b84c48bb44fb7bc37da930053` as the last acceptable UI-shell baseline. The Owner explicitly directed that UI development continue from this version.
19. Live repository reconciliation confirms `dev/ui-shell-v5` was force-reset to `af6ac65306d5e91b84c48bb44fb7bc37da930053`.
20. UI-shell prereleases based on commits `71fd69f3b38660b5ec58c21ffdbaf94c804b99dc` (0.2.9) and `24ebaef3efb882366fbb5c620df80c2c06527621` (0.2.10 hotfix) were rejected by Owner-side runtime validation and removed from the GitHub release channel together with their tags. Their commits remain historical evidence only.
21. Windows Application/.NET Runtime evidence identified a concrete 0.2.9 startup crash: `WebView2CompositionControl` attempted to load `Microsoft.Windows.SDK.NET, Version=10.0.17763.10`; the installed self-contained package lacked that assembly, causing `FileNotFoundException` from `TryInitializeD3DImage()/OnApplyTemplate()`.
22. Windows runtime evidence independently confirmed the earlier context-menu crash: direct access to `CoreWebView2ContextMenuTarget.LinkUri` could throw `COMException 0x8000000E` (“method called at an unexpected time”) and terminate the WPF process.
23. `WebView2CompositionControl` is rejected for the current UI-shell recovery path unless its deployment/runtime dependency chain is independently proven on the Owner's Windows system. Ordinary `WebView2` remains the baseline.
24. Direct `ContextMenuTarget.LinkUri` access is rejected for the custom “Открыть в новой вкладке” feature. URL acquisition must use a safer mechanism such as the already-injected DOM adapter/cache, with optional UI enhancement failing closed rather than terminating the application.
25. CI/build success is insufficient evidence for WebView2 visual/runtime behavior. Loading flashes, tab-switch flashes, downloads, context menus, authentication/profile continuity, and dynamic ChatGPT theming require Owner-side Windows validation.
26. UI recovery must preserve behavior already considered acceptable in 0.2.8, especially Local Bridge restoration after page load, background tab preloading, persistent ChatGPT/WebView profile, and incremental-update continuity.
