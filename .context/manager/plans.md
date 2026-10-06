# Manager plans

Manager generation: 30.
Updated: 2026-10-06 04:30 MSK

## Active private-transport plan

1. Keep the five-second serialized network pacing invariant enforced in every probe/harness/client.
2. Read the latest backing run for `bridge-e2e-oneshot-20261006-0323`'s worker and extract only bounded, non-secret execution evidence: run status/content shape, model response/error text, and any indication that Library read or result-file creation was unavailable or rejected.
3. Classify the failure boundary inside the worker run:
   - prompt/instruction did not execute the requested Library workflow;
   - Scheduled runtime lacked the expected Library/file capability;
   - result creation was attempted but failed;
   - model/run completed with another explicit error or refusal.
4. Modify only the worker contract supported by live evidence. Do not change scheduling again unless new evidence reopens that layer.
5. Start a fresh phased E2E probe with a new probe_id:
   - Phase A: recovery snapshot -> request file -> UTC one-shot arm -> read-back -> exit.
   - Phase B: one independent observation after the scheduled time; verify backing run and result file.
   - Phase C: restore worker and delete transport files.
6. On first full E2E PASS, add READY/ACK plus generation/seq/message_id fencing.
7. Implement production-oriented narrow clients from proven primitives.
8. Run forced interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests and 100+ round trips under the same pacing invariant.
