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

Immediate commitments:
1. Use Local Bridge local CLI as the default GitHub execution path when available.
2. Keep process commands noninteractive and bounded; never expose or persist authentication tokens.
3. Prefer one complete bounded work stage per bridge request.
4. Reconcile proven M4 changes with product authority `main` while preserving the `ea074e0` transport invariant and later M3 durability.
5. Harden intermittent result auto-submit.
6. Add stronger bridge-owned process containment before broad shell/process expansion; Windows Job Object kill-on-close remains the preferred target.
7. Persist significant state updates to `manager-state`; once available, prefer doing so through Local Bridge CLI rather than the connector.
