# Manager beliefs

Manager generation: 31.
Updated: 2026-10-06 05:32 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Autonomous PC Runner Gateway remains the default live-test path; Owner manual UI interaction is fallback-only.
- Owner hard safety invariant remains permanent: every explicit internal/external network/API/backend request must be serialized and separated by at least 5000 ms of quiet time; no bursts or parallel requests.
- Current runner research line is draft PR #30 / exp/runner-private-transport-control-plane. Verified branch head: e1755dbd79ac09652c6f636c30abbaa374105f9c (`test: add paced latest backing run evidence probe`).
- Proven milestones remain: authenticated read-plane, Pause/Resume, Schedule create/update/remove, existing-task arm/rearm with restoration, prompt mutation with restoration, full disposable Library lifecycle with exact byte-for-byte read-back and cleanup, and UTC one-shot Scheduled runtime triggering.
- One-shot Phase A #278 / run 37393691503 PASS; arm-state #279 / run 37394046419 recorded an authoritative future next_run for `DTSTART;TZID=UTC:20261006T003000`.
- Durable state evidence #283 / run 37398824338 recorded run_advanced=true, last_run_present=true, latest_run_http=200, result_found=false, result_verified=false; Phase C #282 / run 37398624121 PASS cleanup/restoration.
- Read-only latest-run probe #284 / run 37399292416 completed with project status `evidence`; GitHub issue callback failed with HTTP 400, so the useful result exists in the workflow log rather than the issue thread.
- #284 returned a valid assistant/final_answer backing-run body whose text says native reading of the program and payload from Library succeeded, but that runtime's available Library interface could not create a new file directly from JSON content without an intermediate external-file mechanism; the worker stopped because that workaround was forbidden.
- Critical timestamp caveat: #284's returned backing-run `created_at` is 2026-10-04T21:56:11.557630Z, predating the current one-shot probe. After Phase C the borrowed task was restored (`is_enabled=false`, `last_run_time=null`). Therefore #284 is strong evidence of a likely worker-runtime capability boundary, but is not yet proof that this exact body belongs to the 2026-10-06 one-shot execution.
- The next experiment must capture and persist the backing-run identity/content before Phase C restoration so the run can be causally tied to the fresh probe.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
