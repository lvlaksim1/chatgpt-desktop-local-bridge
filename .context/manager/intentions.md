# Manager intentions and commitments

## Completed

### BRIDGE-M0A through BRIDGE-M0E
- completed

### BRIDGE-M1
- CLOSED
- canonical live transport baseline: `ea074e0`

### BRIDGE-M2
- CLOSED as a feature milestone
- later adapter hardening must preserve the `ea074e0` transport invariant

## Active

### UI-SHELL-R1 — Recover and stabilize from 0.2.8

Owner directive on 2026-10-03 establishes `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053` as the development baseline after rejecting 0.2.9/0.2.10.

Active commitments:
1. Continue UI-shell work from `af6ac653`, not from the rejected 0.2.9/0.2.10 lineage.
2. Preserve ordinary `WebView2`; do not reintroduce `WebView2CompositionControl` without explicit independent runtime/deployment proof.
3. Replace unsafe direct `ContextMenuTarget.LinkUri` access with a crash-safe target-resolution path.
4. Preserve working Local Bridge restore, background tab preloading, profile continuity, and the incremental updater while UI behavior changes.
5. Deliver one fundamental WebView/UI behavior change per development prerelease where practical, require Owner-side validation, and only then advance to the next change.
6. Address the planned UI backlog: loading flash, loaded-tab switch flash, black/unused browser area, native download behavior, safe “open in new tab”, unified theme coverage, explicit theme reset, and relocation of full Setup to Settings/Updates.
7. After the UI recovery slice is stable, continue diagnostics, transport, permission, tool-expansion, and production-hardening work listed in the active plan.
8. Do not claim the UI recovery complete from CI alone.

### BRIDGE-M3 — Durable execution and delivery
Durable request lifecycle, pending-result persistence, replay-safe classification, conversation-bound recovery, delivered-payload retirement, bounded result transport, and centralized capability registration are substantially implemented on the product lineage.

Reconciliation with the proven `ea074e0` transport behavior remains incomplete.

### BRIDGE-M4 — Controlled mutation and process execution
An `ea074e0`-derived development lineage now exposes live-proven:
- `fs.write_text`
- `fs.append_text`
- `fs.write_file`
- `process.run`

Owner-side validation passed for file append, Git CLI, GitHub CLI authentication, and remote repository access.

Continuing commitments:
1. Use Local Bridge local CLI as the default GitHub execution path when available.
2. Keep process commands noninteractive and bounded; never expose or persist authentication tokens.
3. Prefer one complete bounded work stage per bridge request.
4. Reconcile proven M4 changes with product authority `main` while preserving the `ea074e0` transport invariant and later M3 durability.
5. Harden intermittent result auto-submit.
6. Add stronger bridge-owned process containment before broad shell/process expansion; Windows Job Object kill-on-close remains the preferred target.
7. Persist significant state updates to `manager-state`; once available, prefer doing so through Local Bridge CLI rather than the connector.
