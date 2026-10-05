# Manager beliefs

Manager generation: 24.
Updated: 2026-10-05 17:14 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d; production Local Bridge transport is unchanged.
- Private Transport v5 read-plane is live-proven on the Owner account: scheduled=200, paused=200, library=200, storage=200.
- First write-plane contract is now live-proven from the current frontend: pause uses POST /backend-api/automations/set_status with JSON fields jawbone_id:string and is_enabled:boolean.
- Observed pause body for the tested task: jawbone_id=6ac3ae81a9148191af74770f2ac536b5 and is_enabled=false.
- Pause returned HTTP 201.
- Frontend then performed authoritative-looking read-back through GET /backend-api/automations and GET /backend-api/automation/{id}, both observed with HTTP 200.
- Some parallel GET requests ended net::ERR_ABORTED; treat them as superseded UI requests, not mutation failure, because successful read-back requests followed.
- Next gate is capture Resume for the same task, expected but not yet proven to be the same endpoint with is_enabled=true.
- Do not infer or implement Resume until captured.
- Write reliability rule remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
