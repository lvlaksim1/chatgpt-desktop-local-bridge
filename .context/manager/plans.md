# Manager plans

Manager generation: 28.
Updated: 2026-10-05 20:13 MSK

## Immediate private-transport plan

1. Quarantine the affected E2E probe worker in disabled state; recover its original configuration from a safe source if available, otherwise retire it explicitly.
2. Refactor E2E into three bounded phases:
   - Phase A: persist recovery snapshot, create request file, mutate/arm worker, verify read-back, exit cleanly.
   - Phase B: use a new short-lived session to observe Scheduled run state and Library result-file appearance.
   - Phase C: validate correlation, restore worker from persisted snapshot, delete transport files, verify cleanup.
3. Re-run request-file -> arm -> Scheduled runtime -> result-file under the phased design.
4. On first full PASS, add READY/ACK and generation/seq/message_id fencing.
5. Implement production-oriented narrow clients from the proven primitives.
6. Run forced interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests.
7. Run 100+ sequential round trips and large-payload tests.
8. Only then classify the transport as REJECT / CONTROL-PLANE ONLY / OPTIONAL / DEFAULT.

Other independent tracks remain PR #22 runtime foundation, UI candidate 4c92f81 and PR #23 ChatGPT-plan transport.
