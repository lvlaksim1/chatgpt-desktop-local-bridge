# Manager intentions and commitments

Manager generation: 31.
Updated: 2026-10-06 05:32 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.
Verified live branch head: e1755dbd79ac09652c6f636c30abbaa374105f9c.

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

Current one-shot evidence:
- corrected Phase A #278 / run 37393691503: PASS;
- arm-state #279 / run 37394046419: exact_schedule, target_time_utc present, one future next_run, first_future_delta_sec=322;
- Phase B #281 / run 37398370360: pending/no result file;
- post-observation state #283 / run 37398824338: run_advanced=true, last_run_present=true, latest_run_http=200, result_found=false;
- Phase C #282 / run 37398624121: PASS cleanup/restoration;
- latest-run reader #284 / run 37399292416: project status evidence, issue callback failed HTTP 400 but workflow log contains bounded backing-run evidence;
- #284 body reports Library read success and inability to create a Library file directly from JSON in that worker runtime without a forbidden external-file intermediary;
- #284 body timestamp predates the fresh one-shot probe, so the capability finding is relevant but not yet causally tied to the current run.

Commitments:
1. Keep UTC one-shot scheduling semantics unchanged unless contrary evidence appears.
2. Do not overclaim #284 as the current probe's exact backing run because its created_at predates the probe.
3. Modify the next Phase B/evidence path so it captures run identity/timestamp/body before Phase C restoration.
4. Test the direct Library-write capability explicitly inside a fresh causally tagged worker run.
5. If direct Library result creation is unavailable, investigate only first-party in-product return channels; do not introduce an external intermediary merely to make the experiment pass.
6. Persist recovery snapshot before every E2E mutation and clean up after every terminal observation.
7. Keep main unchanged until promotion evidence exists.
