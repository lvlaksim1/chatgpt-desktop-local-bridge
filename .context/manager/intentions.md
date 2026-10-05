# Manager intentions and commitments

Manager generation: 29.
Updated: 2026-10-05 23:02 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.

Proven:
- authenticated read-plane;
- Pause/Resume;
- Schedule create/update/remove;
- existing-task arm/rearm with restoration;
- existing-task prompt mutation with restoration;
- complete disposable Library lifecycle with exact byte read-back and cleanup.

Safety:
- all explicit network/API/backend requests in research and development must be serialized with a minimum 5000 ms quiet interval;
- no parallel fetches, bursts or sub-5-second polling;
- retries use at least the same minimum delay and should back off further on errors.

Current phased E2E:
- Phase A #249 / run 37363246158 PASS;
- Phase B #250 / run 37363650201 = pending;
- Phase B2 #252 / run 37366501806 = pending;
- state evidence #254 / run 37366897764: worker enabled, run_advanced=false, no last run, latest-run read HTTP 200, no result file, no harness error;
- Phase C #255 / run 37367052654 PASS cleanup/restoration.

Commitments:
1. Do not classify pending Phase B as transport/backend failure.
2. Diagnose Scheduled next-run/trigger semantics using low-rate read-only evidence first.
3. Do not re-arm or mutate until the previous probe is fully reconciled.
4. Persist recovery snapshot before any E2E mutation.
5. Keep main unchanged until promotion evidence exists.
