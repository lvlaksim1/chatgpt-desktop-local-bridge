# DEC-0008 — UI shell rollback and staged runtime validation

Status: ACCEPTED
Date: 2026-10-03
Authority: Owner directive + verified Windows runtime evidence + live GitHub reconciliation

## Decision

The UI-shell development baseline is reset to `0.2.8.0` at commit `af6ac65306d5e91b84c48bb44fb7bc37da930053`.

The 0.2.9 commit `71fd69f3b38660b5ec58c21ffdbaf94c804b99dc` and 0.2.10 hotfix commit `24ebaef3efb882366fbb5c620df80c2c06527621` are rejected as continuation baselines. Their prereleases/tags were removed from the release channel. Their commits remain historical diagnostic evidence.

## Evidence

Owner-side Windows event logs identified:
- startup `FileNotFoundException` in `WebView2CompositionControl.TryInitializeD3DImage()/OnApplyTemplate()` because `Microsoft.Windows.SDK.NET, Version=10.0.17763.10` was not present in the deployed package;
- `COMException 0x8000000E` from direct `CoreWebView2ContextMenuTarget.LinkUri` access during custom context-menu handling.

Live GitHub reconciliation confirmed `dev/ui-shell-v5` points to `af6ac653`.

## Consequences

- Ordinary `WebView2` remains the recovery control.
- `WebView2CompositionControl` must not be reintroduced without independent deployment/runtime proof on the Owner system.
- Direct `ContextMenuTarget.LinkUri` access is prohibited in the recovery lineage; use a safer adapter/cache path.
- Preserve working 0.2.8 behavior while fixing UI defects.
- Prefer one fundamental WebView/UI change per prerelease, use CI for build integrity, and require Owner-side Windows validation before promoting the next baseline.
- Failed experimental releases are diagnostic evidence, not merge sources to be reapplied wholesale.
