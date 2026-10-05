# Manager beliefs

Manager generation: 28.
Updated: 2026-10-05 20:13 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Autonomous PC Runner Gateway is the default live-test path; Owner manual UI interaction is fallback-only.
- Current runner research line is draft PR #30 / exp/runner-private-transport-control-plane / head 198b3ba8f553db78888115ec1d18061fe89a1305.
- Authenticated private read-plane is proven.
- Pause/Resume with authoritative read-back and restoration is proven.
- Task Schedule create/update/remove is proven using the current frontend serializer.
- Existing-task arm/rearm with restoration is proven on run 37341819835.
- Existing-task prompt mutation with restoration is proven on run 37342848518.
- Full disposable Library lifecycle is proven: allocate, signed upload, terminal processing completion, Library discovery, exact byte-for-byte download, rename/read-back, delete/cleanup. Latest proof run 37336624243.
- Dedicated new-worker creation remains unresolved; current progress does not depend on solving it immediately because existing task mutation/arming is proven.
- First full Scheduled Tasks + Library E2E attempt (#240 / run 37343267811) did not return terminal evidence because the long-lived diagnostic CDP WebSocket closed unexpectedly.
- That E2E failure is classified as harness/session failure, not backend rejection.
- Reconciliation #241 / run 37344708850 PASS: temporary E2E worker found, request file present, result file absent, worker run state had not advanced; runner disabled the worker and cleaned the request file.
- Normal desktop application restore #243 / run 37345374055 PASS.
- The temporary E2E worker remains quarantined disabled until its pre-test configuration is safely recovered or the task is retired.
- Future E2E must be crash-safe and split into short transactional phases with durable recovery metadata persisted before mutation.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
