# Manager plans

Manager generation: 16.
Product authority: `main`.
Current known authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Current UI recovery baseline: `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053` on `dev/ui-shell-v5`.

## Closed milestones
- BRIDGE-M1: CLOSED.
- BRIDGE-M2: CLOSED.

## UI-SHELL-R1 recovery plan

0.2.9 and 0.2.10 are rejected runtime lineages. Do not port them wholesale back onto the accepted baseline.

Use a staged validation sequence from `af6ac653`:
1. Preserve ordinary `WebView2` and first fix the loading/black-area behavior without changing the browser-control class. Keep the custom “Загрузка ChatGPT…” cover until a safe visual-ready criterion, but do not use a composition control.
2. Separately address switching between already-loaded tabs so the preloaded WebViews remain warm and switching does not introduce a white/blue/black intermediate frame.
3. Preserve background tab preloading throughout.
4. Restore native/expected download behavior for ordinary clicks. Normal site navigation/download behavior must not be repurposed into an app-tab action.
5. Reintroduce “Открыть в новой вкладке” only as an explicit custom context-menu command. Resolve the target via a safe pre-captured DOM/adapter path; never depend on direct `ContextMenuTarget.LinkUri` access.
6. Harden optional UI handlers so context-menu/theme/link failures cannot terminate the whole application.
7. Expand unified theme coverage across ChatGPT surfaces and dynamic UI without making the theme layer a startup dependency.
8. Add an explicit theme reset/default action.
9. Keep the ordinary top-panel update path delta-only; place full Setup under Settings → Updates as recovery/fallback.
10. After the above UI recovery steps pass Owner validation, add Diagnostics improvements: filters by tab/tool/request ID, copy, expand request/result, diagnostics bundle export, and explicit distinction between local execution success and result-delivery failure.
11. Research and harden result transport so large results rely less on, or can eventually avoid, ChatGPT composer automation while keeping the no-OpenAI-API constraint.
12. Implement real fine-grained `ASK` permission UX: action/path/process-aware Allow once / Always allow / Deny.
13. Expand local tools only after transport and permissions are stable: stat/hash, line-range read, atomic patch/edit, then higher-level process/files capabilities.
14. Production hardening: E2E launch → tabs → bridge → tool → result → update → restart; multi-monitor/DPI; temp cleanup; installer/uninstaller; app icon; Russian UI consistency.
15. Merge verified UI work toward product authority only after the development lineage is stable and Owner validation is complete.

Validation discipline:
- prefer one fundamental WebView/UI behavior change per prerelease;
- require Windows CI for compile/package integrity;
- require Owner-side signed-in Windows evidence for WebView/ChatGPT runtime behavior;
- if a step regresses runtime behavior, revert only that step and keep the last accepted baseline.

## BRIDGE-M3
Durable execution/delivery is substantially implemented on `main`, but the product lineage must still be reconciled with the proven `ea074e0` transport behavior.

## BRIDGE-M4 proven slice

Filesystem mutation:
- branch `m4-write-tools-ea074e0`
- commits `c13781814ade651ee6b7d51f37a4b37ad997491b`, `826674c158df8ad868ec85823adbc2b38bb1653d`
- workflow commit `38c2aca554268a07343b8e1a6c805e787b3971f9`
- prerelease `dev-ea074e0-write-tools`
- live `fs.append_text(D:/test/file.txt)`: PASS

Process/CLI:
- branch `m4-process-run-write-tools`
- commits `a2c00c7619506c5aa0e98a523fc4b14ad255d141`, `ef2ac99a73cdc3c9a8fba8965d3a6ee9714e2753`
- workflow commit `cdb78c9d5f1a230d012f26fca1e391be5c5c23f9`
- prerelease `dev-process-run`
- local Git, GitHub CLI, GitHub auth, and remote repo query: PASS

Distribution:
- full setup SHA-256 `ceec3c9c0204624979ee344b7a26a59821247618bc43645c9493f4dfbcf35d60`
- incremental updater SHA-256 `03fde14068ca7159ed8be3c7f3b9d6b8d861f9cff58b5ae20bca82cf35d61fd6`

## Cross-track plan
1. Stabilize the UI recovery lineage from 0.2.8 without disturbing the proven bridge behavior.
2. Treat Local Bridge + local CLI as the normal GitHub-control channel when available.
3. Reconcile the proven write/process lineage with `main` without reintroducing the post-`ea074e0` transport regression or discarding M3 durability.
4. Reproduce and harden the staged-but-not-auto-sent result condition.
5. Add stronger bridge-owned process containment before broad shell/process expansion.
6. After reconciliation, rerun the unchanged `win.ini` benchmark plus write/process smoke tests.
7. Keep development-release retention clean and avoid unnecessary large Actions artifacts.
