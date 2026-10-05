# Manager intentions and commitments

Manager generation: 28.
Updated: 2026-10-05 20:13 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane / 198b3ba8f553db78888115ec1d18061fe89a1305.

Proven:
- authenticated read-plane;
- Pause/Resume;
- Schedule create/update/remove;
- existing-task arm/rearm with restoration;
- existing-task prompt mutation with restoration;
- complete disposable Library lifecycle with exact byte read-back and cleanup.

Current E2E finding:
- request #240 / run 37343267811 failed because the long-lived diagnostic WebSocket closed before terminal evidence;
- reconciliation #241 / run 37344708850 safely established that the worker had not completed, disabled it and cleaned the request file;
- app restore #243 / run 37345374055 PASS.

Commitments:
1. Do not treat #240 as backend rejection.
2. Keep the affected E2E worker disabled until safely recovered or retired.
3. Replace monolithic E2E with short crash-safe phases and persisted recovery snapshot before mutation.
4. Use fresh independent observation/reconciliation sessions instead of one long-lived WebSocket.
5. Require authoritative read-back after every write and on every ambiguous outcome.
6. Keep main unchanged until promotion evidence exists.
