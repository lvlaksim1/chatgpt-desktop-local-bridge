# Manager intentions and commitments

## Completed

### BRIDGE-M0A — Install/upgrade channel
- completed

### BRIDGE-M0B — Repository/release storage hygiene
- completed

### BRIDGE-M0C — Incremental update channel
- completed

### BRIDGE-M0D — Single-file incremental updater
- completed
- real Windows legacy/update E2E evidence exists

### BRIDGE-M0E — Delta-safe uninstall behavior
- completed
- normal uninstall asks whether to delete settings/working data
- quiet uninstall preserves user data
- automated preservation E2E exists

### BRIDGE-M1 — Live end-to-end bridge proof
- completed
- READY and `fs.read_text` proven on the Owner PC
- final product-release regression: pc-runner-gateway #166

### BRIDGE-M2 — Web adapter reliability hardening
- completed
- strict exact-envelope parser retained
- payload-free malformed-request diagnostics added and deterministically tested
- ordinary user drafts are protected
- only bridge-owned stale drafts may be replaced
- live reliability regression: pc-runner-gateway #168 PASS on `dev-aea8ad2`

## Active

### BRIDGE-M3 — Durable execution foundation
- active
- foundation merged to `main@64152b68205a59e7df59d842c2acf972f717de33`
- durable request lifecycle and separate delivery state are implemented
- duplicate execution is no longer RAM-only
- one deterministic restart/dedupe/conflict regression is wired into CI and PASS
- next: design and implement bounded result persistence/replay for `completed/pending` without re-executing the local tool
- follow with capability registry and bounded result transport
- avoid a new Owner update for every internal M3 sub-step; publish and live-test a coherent M3 slice

### BRIDGE-M4 — Controlled mutating/process capabilities
- accepted; follows reliability foundations
