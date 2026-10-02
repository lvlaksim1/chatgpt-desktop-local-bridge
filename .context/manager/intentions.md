# Manager intentions and commitments

## Completed

### BRIDGE-M0A through BRIDGE-M0E
- completed

### BRIDGE-M1
- CLOSED
- canonical live transport baseline is now explicitly pinned to application source `ea074e0`

### BRIDGE-M2
- CLOSED as a feature milestone
- any M2 adapter hardening must be rechecked against the `ea074e0` transport invariant

## Active

### BRIDGE-M3 — Durable execution and delivery
Implemented product foundation:
- durable request lifecycle;
- persisted pending result envelope;
- replay-safe state classification;
- conversation-bound recovery;
- delivered-payload retirement;
- 256 KiB serialized-result bound;
- centralized capability registry.

Current live blocker:
- post-`ea074e0` transport regression prevents reliable bootstrap/READY on current code.

Canonical proof:
- Owner manually revalidated exact-morning `ea074e0` with the `C:/Windows/win.ini` scenario;
- full request -> local read -> result -> final ChatGPT answer succeeded visibly;
- app reported `fs.read_text completed in 2 ms.`.

Immediate commitment:
1. Treat the complete `ea074e0` send/bootstrap behavior as immutable reference behavior.
2. Stop inventing alternative send transports while this baseline exists.
3. Diff post-`ea074e0` changes affecting MainWindow send logic, bridge adapter, bootstrap/READY handling, message hiding and conversation handling.
4. Reintroduce later M2/M3 changes in small groups while preserving the exact `win.ini` benchmark after each transport-relevant group.
5. Only after the benchmark remains PASS on current M3 code, resume final durable-ledger live validation.
