# Manager beliefs

Manager generation: 30.
Updated: 2026-10-06 04:30 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Autonomous PC Runner Gateway remains the default live-test path; Owner manual UI interaction is fallback-only.
- Owner hard safety invariant remains permanent: every explicit internal/external network/API/backend request must be serialized and separated by at least 5000 ms of quiet time; no bursts or parallel requests.
- The pacing invariant remains enforced in the private-transport research line; validator runs #275 / 37393364198 and #277 / 37393614131 PASS after the one-shot scheduling changes.
- Current runner research line is draft PR #30 / exp/runner-private-transport-control-plane. Live branch head is d6bd1d7ea29063246b6000f72c9c8ab8c1d275fd, ten commits ahead of generation-29 helper head 99ff3c8124e7615e883034776a676146d0ad140f.
- Proven milestones remain: authenticated read-plane, Pause/Resume, Schedule create/update/remove, existing-task arm/rearm with restoration, prompt mutation with restoration, and full disposable Library lifecycle with exact byte-for-byte read-back and cleanup.
- Recovered timezone evidence from #273 / run 37392429164: Scheduled Tasks backend reports default_timezone=Europe/Moscow; a known enabled comparator had recent last_run_time, future next_run_times and latest backing run HTTP 200. Scheduled runtime execution is therefore live on the account.
- The old paced probe's trigger diagnosis has been superseded by the UTC one-shot experiment.
- One-shot Phase A #278 / run 37393691503 PASS using schedule `DTSTART;TZID=UTC:20261006T003000`; authoritative arm-state #279 / run 37394046419 recorded timing_mode=exact_schedule, target_time_utc present, one future next_run and first_future_delta_sec=322.
- One-shot Phase B #281 / run 37398370360 returned project status pending after the scheduled time had long passed.
- Durable local state evidence #283 / run 37398824338 proves the worker DID execute: run_advanced=true, last_run_present=true, latest_run_http=200, but result_found=false and result_verified=false.
- Therefore Scheduled runtime triggering/next-run semantics are no longer the current blocker. The current blocker is inside the worker run/result-production path after successful Scheduled execution.
- Phase C cleanup #282 / run 37398624121 PASS; borrowed worker and transport files were restored/cleaned.
- Future diagnosis must inspect the worker's latest backing run and determine why a completed Scheduled run produced no Library result file, while preserving five-second serialized pacing.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
