# Manager beliefs

Manager generation: 27.
Updated: 2026-10-05 20:02 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge remains unchanged.
- Autonomous PC Runner Gateway is the default live-test path; Owner manual UI interaction is fallback-only.
- Authenticated read-plane, Pause/Resume, Task Schedule create/update/remove, existing-task arm/rearm, existing-task prompt mutation and full disposable Library lifecycle are proven.
- Library lifecycle proof includes exact byte-for-byte read-back and cleanup.
- Dedicated new-worker creation remains unresolved and is not required for the next E2E attempt.
- First full Scheduled+Library E2E attempt (#240) did not return terminal evidence because the long-lived diagnostic WebSocket closed.
- Reconciliation (#241) proved the worker had not completed: request file existed, result file did not, worker run state had not advanced. The runner disabled the temporary worker and cleaned the request file.
- Ordinary desktop application restoration after reconciliation (#243) PASS.
- The temporary E2E worker is quarantined in disabled state until its pre-test configuration is safely recovered or the probe task is explicitly retired.
- Future E2E probes must persist recovery state before mutation and must not rely on one long-lived diagnostic session for cleanup.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No credentials, tokens or cookies are persisted.
