# Manager plans

Manager generation: 27.
Updated: 2026-10-05 20:02 MSK

## Active private-transport plan

1. Keep the quarantined E2E probe worker disabled; recover its pre-test configuration from a safe source if possible, otherwise explicitly retire it.
2. Replace the monolithic E2E probe with a crash-safe multi-phase harness:
   - Phase A: persist recovery snapshot, create request file, mutate/arm worker, verify read-back, exit;
   - Phase B: observe Scheduled run state and Library result through fresh short-lived sessions;
   - Phase C: verify correlation/ACK, restore worker from persisted snapshot, delete transport files, verify cleanup.
3. Retry the same full-file transport E2E under this bounded design.
4. On E2E PASS, add explicit READY/ACK and generation/seq/message_id fencing.
5. Implement narrow production-oriented clients from proven primitives.
6. Run restart, duplicate, stale-ACK, relogin/navigation, forced network-loss, orphan-cleanup and 100+ round-trip campaign.
7. Classify transport as REJECT / CONTROL-PLANE ONLY / OPTIONAL / DEFAULT only after evidence.
