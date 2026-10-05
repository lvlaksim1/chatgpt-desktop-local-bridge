# Manager plans

Manager generation: 24.
Updated: 2026-10-05 17:14 MSK

## Immediate write-plane plan
1. Resume the same paused task using the ordinary ChatGPT UI after pressing Task: Resume marker.
2. Capture the resulting mutation and read-back requests.
3. Confirm whether Resume is the same POST /backend-api/automations/set_status with is_enabled=true.
4. Then capture Task Schedule edit.
5. Then identify current one-shot arm/rearm contract.
6. After task control-plane contracts are proven, capture Library/file lifecycle.
7. Implement narrow clients only from proven contracts.
8. Execute first request.json -> READY -> arm -> result.json -> ACK -> Desktop E2E.
