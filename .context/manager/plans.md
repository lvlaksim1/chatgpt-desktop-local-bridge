# Manager plans

Manager generation: 23.
Updated: 2026-10-05 16:31 MSK

## Immediate plan: write-plane discovery
1. Keep Transport Probe capture ON.
2. Capture one task pause action with TASK_PAUSE marker.
3. Capture the matching task resume action with TASK_RESUME marker.
4. Capture schedule edit with TASK_SCHEDULE marker.
5. Capture one-shot arm/rearm behavior if the frontend exposes it.
6. Capture Library/file create/upload, read, replace/update and delete using LIB_* markers.
7. Record method/path/request schema/response schema and identify authoritative read-back for each write.
8. Implement narrow write clients only after contracts are confirmed.
9. Run disposable request.json/result.json file lifecycle.
10. Execute first full server-side E2E, then durability/endurance matrix.

Other tracks remain independent: PR #22 runtime foundation, UI candidate 4c92f81, PR #23 ChatGPT-plan transport.
