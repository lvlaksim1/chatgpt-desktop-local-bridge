# Manager beliefs

Manager generation: 33.
Updated: 2026-10-06 07:35 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge remains unchanged.
- Autonomous PC Runner Gateway remains the default live-test path.
- Owner safety invariant remains permanent: serialize every explicit network/API/backend request with at least 5000 ms quiet time; no bursts or parallel requests.
- Research line remains PR #30 / exp/runner-private-transport-control-plane. Prompt transport test commit: 4e5843209b2b67d12750594256047a62cfc21cf5.
- Proven before this generation: authenticated read-plane; Pause/Resume; schedule mutation; existing-task arm/rearm and prompt mutation with restoration; Desktop-side Library lifecycle; UTC one-shot Scheduled triggering; causal run correlation.
- Library request path is not usable as tested: a fresh Desktop-created Library request file was not visible to the causally matched Scheduled worker.
- New proven milestone: bounded prompt-as-request + latest_backing_run-as-result transport completed end-to-end without relying on Library for the response path.
- Prompt probe `bridge-e2e-prompt-20261006-0718`: Phase A #294 / run 37413075306 PASS; Phase B #295 / run 37413346604 Project PASS; Phase C #296 / run 37414107982 PASS cleanup/restoration; ledger evidence #297 / run 37414262277.
- Ledger evidence proves the Phase B PASS was prompt-based: stage=transport_verified, run_advanced=true, latest run is fresh and tagged, result_found=false, result_verified=false, yet project_status=pass.
- Fresh prompt run identifiers: last_run_time=2026-10-06T04:28:37.245364Z; latest_run_id=6e4454a6-faff-46f3-b926-dc389f2ace0b; latest_run_created_at=2026-10-06T04:28:35.000004Z; probe/message tags true; automation_latest_update_is_from_latest_run=true; automation_last_backing_run_failed=false.
- Because the executing code defines PASS as result_verified OR prompt_result_verified, and result_verified=false, the observed PASS proves prompt_result_verified=true.
- This is the first proven no-composer/no-DOM-input Desktop -> Scheduled runtime -> Desktop round trip in the research line.
- Current proof applies to a small bounded payload only. Production framing, generation/seq fencing, duplicate suppression, stale-response rejection and endurance are not yet proven.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
