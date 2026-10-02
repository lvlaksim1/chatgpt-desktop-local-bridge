# Manager intentions and commitments

## Completed

### BRIDGE-M0A through BRIDGE-M0E
- install/upgrade, storage hygiene, incremental updates, single-file updater, and delta-safe uninstall are completed.

### BRIDGE-M1 — Live end-to-end bridge proof
- completed
- READY and `fs.read_text` proven on the Owner PC

### BRIDGE-M2 — Web adapter reliability hardening
- completed
- strict protocol diagnostics, draft protection, and stale bridge-draft recovery are live-proven

## Active

### BRIDGE-M3 — Durable execution and delivery
- product implementation is substantially complete
- durable request ledger survives restart
- execution and delivery states are separate
- bounded pending result payload is persisted
- replay decisions prevent blind re-execution
- pending results are recoverable only in the originating conversation
- delivered payloads are retired
- serialized result transport is capped at 256 KiB
- capability registry is centralized
- deterministic CI coverage exists

### Immediate commitment
1. Finish the two currently running CI workflows for `dd26c48` and `9461fff`.
2. If both are green, update the Owner PC once: `dev-85c714c -> dev-31e823e`.
3. Run exactly one bounded M3 live regression.
4. On PASS, close the current M3 durable-foundation slice and persist evidence.
5. On FAIL, analyze the single concrete failure before writing any further test variant.

### BRIDGE-M4 — Controlled mutating/process capabilities
- follows M3 closure
