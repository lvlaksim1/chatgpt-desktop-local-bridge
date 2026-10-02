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
- status: completed
- product release: `dev-ea074e0@ea074e06bd4e959106f49f57cad1ac731597dac3`
- live READY proof: pc-runner-gateway issue #160
- live local read round trip proof: issue #164
- final product-release regression: issue #166
- proven chain: Initialize -> nonce-bound READY -> LOCAL_BRIDGE_REQUEST_V1 -> fs.read_text -> LOCAL_BRIDGE_RESULT_V1/local audit
- path-format defect found during proof and fixed by requiring forward-slash Windows paths in bridge JSON

## Active

### BRIDGE-M2 — Web adapter reliability hardening
- active
- first task: make malformed bridge-request candidates diagnosable immediately without weakening the strict request envelope
- retain fail-closed DOM behavior, current+legacy selectors, streaming stability gate, draft preservation, and no blind retries
- require bounded focused tests, not broad repeated E2E runs

### BRIDGE-M3 — Durable execution foundation
- accepted; follows M2
- explicit state machine, capability registry, bounded results, durable request ledger, delivery recovery

### BRIDGE-M4 — Controlled mutating/process capabilities
- accepted; follows reliability foundations
