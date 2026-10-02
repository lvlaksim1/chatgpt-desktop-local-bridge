# Manager plans

Manager generation: 14.
Product authority: `main`.
Current known product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.

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

## Canonical live transport proof
On 2026-10-02 the Owner manually installed the exact-morning benchmark build based on `ea074e0` and repeated the same `fs.read_text(C:/Windows/win.ini)` flow used in the morning.

Observed PASS:
- bridge request reached the local client;
- `fs.read_text` completed locally in 2 ms;
- `LOCAL_BRIDGE_RESULT_V1` appeared in the ChatGPT conversation;
- ChatGPT produced the normal final answer with the actual `win.ini` contents including `[Mail]` / `MAPI=1`.

This is the transport acceptance benchmark.

## Regression evidence
- current/post-`ea074e0` builds fail before READY in the same benchmark;
- merely restoring `form.requestSubmit()` on current code did not restore the benchmark;
- therefore the defect lies in the broader set of transport/adapter/bootstrap changes after `ea074e0`.

## Immediate plan
1. Preserve the exact `ea074e0` application behavior as the baseline.
2. Produce a focused diff from `ea074e0` to current transport-sensitive code.
3. Partition changes into:
   - transport/send mechanics;
   - adapter message detection/hiding;
   - READY/bootstrap handling;
   - M2 safety hardening;
   - M3 durable/recovery behavior.
4. Reapply later changes incrementally around the baseline, keeping the `win.ini` benchmark unchanged.
5. After each transport-relevant integration point, require visible benchmark PASS, not only DOM/status heuristics.
6. Once current M3 code preserves the benchmark, run the durable M3 live assertions exactly once and close M3 if they pass.

## Release discipline
- Do not replace the proven baseline with a new transport design without evidence.
- Keep the temporary exact-morning benchmark installer/release available until the regression is resolved.
- Minimize GitHub/external requests in interactive conversation because the Owner's environment subjects them to slow additional review.
