# Manager beliefs

Manager generation: 29.
Updated: 2026-10-05 23:02 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Autonomous PC Runner Gateway remains the default live-test path; Owner manual UI interaction is fallback-only.
- Owner hard safety invariant is now permanent: every explicit internal/external network/API/backend request must be serialized and separated by at least 5000 ms of quiet time; no bursts or parallel requests.
- The pacing invariant is codified on the research branch by policy commit 45e14b348a5d5b6df5cc9fea05a53b55d30ab458 and enforced in the phased harness through pacedFetch plus 5-second localhost discovery polling.
- Pacing/syntax validator PASS: run 37363131880.
- Current runner research line is draft PR #30 / exp/runner-private-transport-control-plane. Latest local-state evidence helper commit is 99ff3c8124e7615e883034776a676146d0ad140f.
- Proven milestones remain: authenticated read-plane, Pause/Resume, Schedule create/update/remove, existing-task arm/rearm with restoration, prompt mutation with restoration, and full disposable Library lifecycle with exact byte-for-byte read-back and cleanup.
- Crash-safe phased E2E harness is implemented. Phase A persists recovery state before mutation, creates/verifies request file, mutates/arms the worker, confirms read-back and exits.
- Phase A probe bridge-e2e-paced-20261005-2224 PASS: request #249 / run 37363246158.
- Phase B observation #250 / run 37363650201 completed safely but project status was pending.
- A second independent Phase B observation #252 / run 37366501806 also returned project status pending.
- Local safe state evidence #254 / run 37366897764 proved the precise reason for pending: worker remained enabled, but run_advanced=false, last_run_present=false, latest_run endpoint HTTP 200, no result file was found, and no harness error was recorded.
- Therefore the current blocker is Scheduled runtime triggering/next-run semantics after the proven arm mutation, not Library data-plane and not result verification.
- Phase C cleanup #255 / run 37367052654 PASS; the borrowed worker and transport files were restored/cleaned under the harness assertions.
- Future diagnosis must inspect next_run_times/timing fields and compare against a known successfully executing task, while preserving 5-second serialized pacing.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
