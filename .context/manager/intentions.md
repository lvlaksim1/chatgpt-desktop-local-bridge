# Manager intentions and commitments

Manager generation: 30.
Updated: 2026-10-06 04:30 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.
Live branch head: d6bd1d7ea29063246b6000f72c9c8ab8c1d275fd.

Proven:
- authenticated read-plane;
- Pause/Resume;
- Schedule create/update/remove;
- existing-task arm/rearm with restoration;
- existing-task prompt mutation with restoration;
- complete disposable Library lifecycle with exact byte read-back and cleanup;
- Scheduled runtime trigger of a safely borrowed worker using a UTC one-shot VEVENT.

Safety:
- all explicit network/API/backend requests in research and development must be serialized with a minimum 5000 ms quiet interval;
- no parallel fetches, bursts or sub-5-second polling;
- retries use at least the same minimum delay and should back off further on errors.

Current one-shot E2E:
- timezone semantics #273 / run 37392429164: Scheduled runtime and recent comparator execution confirmed;
- pacing #275 / run 37393364198 and #277 / run 37393614131: PASS;
- first one-shot Phase A #276 / run 37393445835 failed locally on CDP URI normalization before safe mutation;
- corrected one-shot Phase A #278 / run 37393691503: PASS;
- arm-state #279 / run 37394046419: exact_schedule, target_time_utc present, one future next_run, first_future_delta_sec=322;
- Phase B #281 / run 37398370360: pending;
- post-cleanup state #283 / run 37398824338: run_advanced=true, last_run_present=true, latest_run_http=200, result_found=false;
- Phase C #282 / run 37398624121: PASS cleanup/restoration.

Commitments:
1. Treat Scheduled triggering as proven for the UTC one-shot path; do not continue diagnosing it as the primary blocker.
2. Inspect the latest backing run of the executed worker before changing the worker prompt or transport protocol.
3. Determine why the worker run produced no Library result file.
4. Do not re-arm or mutate a worker until the previous probe is fully reconciled and the backing-run evidence is understood.
5. Persist recovery snapshot before every E2E mutation and clean up after every terminal observation.
6. Keep main unchanged until promotion evidence exists.
