# Current blockers and open risks

Updated: 2026-10-05 20:13 MSK

No blocker remains for:
- authenticated read-plane;
- Pause/Resume;
- schedule mutation;
- existing-task arm/rearm;
- prompt mutation;
- Library file lifecycle.

Current proof gaps:
- first complete Scheduled runtime request-file -> result-file execution is not yet proven;
- monolithic runner E2E cannot safely rely on one long-lived CDP/WebSocket session;
- affected temporary E2E worker must remain disabled until recovered or retired;
- dedicated new-worker creation is unresolved;
- READY/ACK and generation/seq/message_id fencing are not yet implemented;
- forced interruption/network-loss recovery and endurance are untested.

Safety rule: persist recovery state before mutation and reconcile interrupted probes before re-enabling any affected task.
