# Manager plans

Manager generation: 11.
Product authority: `main`.
Current product head: `9461fffbacceceeb6f1404bebf76d521e4578c01`.
Latest published release: `dev-31e823e@31e823ef7854a18bb2ad10e94ec71c51814628eb`.
Owner-installed release: `dev-85c714c@85c714c9b46df2c8ea5329b2d265953d9735ee3f`.

## Closed milestones

1. BRIDGE-M1 — CLOSED.
2. BRIDGE-M2 — CLOSED.

## BRIDGE-M3 implemented foundation

1. Durable request reservation and execution state.
2. Separate durable delivery state.
3. Persisted bounded pending result envelope.
4. Explicit replay classification; uncertain execution never reruns blindly.
5. Conversation-bound pending-result recovery.
6. Already-delivered result suppression and payload retirement.
7. Central 256 KiB serialized-result transport bound.
8. Central capability registry for dispatch, permissions, metadata and bootstrap.
9. Deterministic regression coverage in CI.

## Current validation state

- Owner machine successfully updated to `dev-85c714c` via gateway #169.
- Crash-recovery/live probes #170-#173 did not produce final M3 proof; failures were in send/test-harness paths.
- Latest published coherent target is `dev-31e823e`.
- `main@dd26c48` contains the exact owner update task `dev-85c714c -> dev-31e823e`.
- `main@9461fff` contains the bounded final live regression.
- Both corresponding CI runs are currently in progress.

## Immediate plan

1. Do not add another probe while the two current CI runs are unresolved.
2. After both are green, issue one gateway update to `dev-31e823e`.
3. Immediately follow with one gateway run of the bounded M3 live regression.
4. PASS criteria:
   - bridge READY;
   - real `fs.read_text(C:/Windows/win.ini)` succeeds;
   - durable record is `executionState=completed`;
   - durable record is `deliveryState=delivered`;
   - conversation binding matches the active ChatGPT conversation;
   - `resultEnvelopeJson` is retired after delivery.
5. If PASS, close this M3 slice and proceed toward BRIDGE-M4 preparation.
6. If FAIL, diagnose only that failure before changing product or tests.

## Release discipline

- One coherent owner update, not a release per internal step.
- No ZIP deltas.
- No unnecessary Actions artifacts.
