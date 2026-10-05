# Manager plans

Manager generation: 29.
Updated: 2026-10-05 23:02 MSK

## Active private-transport plan

1. Keep the five-second serialized network pacing invariant enforced in every new probe/harness/client.
2. Inspect a known executing Scheduled Task and compare timing_mode, schedule, target_time_utc, next_run_times and latest backing run semantics with the Phase A armed worker.
3. Determine why the Phase A worker remained enabled but never advanced its run state.
4. Correct only the scheduling/arming semantics supported by live evidence; do not increase polling frequency.
5. Re-run phased E2E:
   - Phase A: snapshot -> request file -> worker mutation/arm -> read-back -> exit.
   - Phase B: independent observation after an appropriate wait; verify worker run and result file.
   - Phase C: restore worker and delete transport files.
6. On first full E2E PASS, add READY/ACK plus generation/seq/message_id fencing.
7. Implement production-oriented narrow clients from proven primitives.
8. Run forced interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests and 100+ round trips under the same pacing invariant.
