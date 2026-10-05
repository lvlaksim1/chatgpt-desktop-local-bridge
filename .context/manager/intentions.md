# Manager intentions and commitments

Manager generation: 27.
Updated: 2026-10-05 20:02 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.

Proven milestones:
- read-plane PASS;
- Pause/Resume PASS;
- Schedule create/update/remove PASS;
- existing-task arm/rearm PASS with restoration;
- existing-task prompt mutation PASS with restoration;
- Library disposable lifecycle PASS including exact byte read-back and cleanup.

Current E2E finding:
- attempt #240 failed at the runner harness/session layer because the diagnostic WebSocket closed before terminal evidence returned;
- reconciliation #241 found request present, no result, no completed worker run, and disabled/cleaned the temporary state;
- app restore #243 PASS.

Commitments:
1. Do not classify #240 as backend rejection.
2. Keep the affected probe worker disabled until safely recovered or retired.
3. Redesign E2E into bounded phases with durable recovery state before mutation.
4. Use fresh short-lived observation/reconciliation sessions rather than one long blocking diagnostic call.
5. Add READY/ACK and generation/seq/message_id fencing after the first complete request->worker->result cycle.
6. Keep main unchanged until promotion evidence exists.
