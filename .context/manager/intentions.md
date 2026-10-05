# Manager intentions and commitments

Manager generation: 24.
Updated: 2026-10-05 17:14 MSK

Current private transport candidate remains PR #29 / exp/chatgpt-private-transport-v5 / 95dd011593fd28b570831fc2995d26bef0691f27.

Live evidence:
- read-plane PASS.
- Pause mutation contract captured from current frontend:
  POST /backend-api/automations/set_status
  body schema: jawbone_id:string, is_enabled:boolean
  tested value: is_enabled=false
  response: HTTP 201
  read-back: GET /backend-api/automations and GET /backend-api/automation/{id}, HTTP 200.

Commitments:
1. Do not replay or implement unobserved mutations.
2. Capture Resume next on the same task.
3. After Resume, capture schedule edit and one-shot arm/rearm behavior.
4. Then capture Library/file create-upload-read-replace-delete contracts.
5. Preserve UNKNOWN_OUTCOME -> read-back -> reconcile for writes.
