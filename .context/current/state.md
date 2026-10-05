# Current state

Updated: 2026-10-05 17:14 MSK

- manager generation: 24
- product main: 6e2a0b54b727c5474bad40ac038f727a39cceb8d
- current private transport candidate: PR #29 / exp/chatgpt-private-transport-v5
- read-plane: PASS
- first write-plane primitive: Pause captured and proven
- pause endpoint: POST /backend-api/automations/set_status
- pause body schema: jawbone_id:string, is_enabled:boolean
- tested pause value: is_enabled=false
- pause response: HTTP 201
- read-back observed: GET /backend-api/automations and GET /backend-api/automation/{id} with HTTP 200
- next gate: Resume capture
