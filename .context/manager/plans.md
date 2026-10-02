# Manager plans

Manager generation: 12.
Product authority: `main`.
Current product head: `9461fffbacceceeb6f1404bebf76d521e4578c01`.
Current published and Owner-installed release: `dev-31e823e@31e823ef7854a18bb2ad10e94ec71c51814628eb`.

## Closed milestones
- BRIDGE-M1: CLOSED.
- BRIDGE-M2: CLOSED.

## BRIDGE-M3 product foundation
Implemented:
1. durable request execution states;
2. separate durable result-delivery states;
3. persisted bounded pending result payload;
4. replay classification that blocks uncertain execution;
5. originating-conversation recovery;
6. suppression of already delivered replay and payload retirement;
7. 256 KiB result transport bound;
8. single capability registry;
9. deterministic CI coverage.

## Current live evidence
- #174: `dev-85c714c -> dev-31e823e` update PASS.
- #175: bounded final M3 live regression FAIL.
- Failure: `Chat send failed: native-submit-not-confirmed` during Initialize Bridge.
- The regression did not reach the durable read/ledger PASS criteria.
- Exact update/regression CI is green.
- #176 is closed as duplicate and must not be treated as additional evidence.

## Immediate plan
1. Inspect the send path around `submitNativeSend()` and `SendTextToChatAsync()`.
2. Reconcile what `form.requestSubmit()` guarantees versus the current confirmation heuristic `composerEmpty`.
3. Determine from existing DOM/status evidence whether submit happened but confirmation missed it, or submit itself was not accepted.
4. Make one targeted fix if warranted.
5. Re-run only `.pc-gateway/tasks/Probe-BridgeM3Durable.ps1`.
6. Close M3 durable foundation only after real `fs.read_text` and ledger `completed/delivered` PASS.

## Release discipline
- No repeat update while `dev-31e823e` is installed.
- No new broad probes.
