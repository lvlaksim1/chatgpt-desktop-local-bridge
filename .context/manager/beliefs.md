# Manager beliefs

Manager generation: 32.
Updated: 2026-10-06 07:14 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Autonomous PC Runner Gateway remains the default live-test path; Owner manual UI interaction is fallback-only.
- Owner hard safety invariant remains permanent: every explicit internal/external network/API/backend request must be serialized and separated by at least 5000 ms of quiet time; no bursts or parallel requests.
- Current runner research line is draft PR #30 / exp/runner-private-transport-control-plane. Verified research head is fe87cab8cddbcb2b3de9befe367eea2220b4ef46.
- Proven milestones: authenticated read-plane; Pause/Resume; schedule create/update/remove; existing-task arm/rearm and prompt mutation with restoration; disposable Library lifecycle from Desktop with exact byte read-back and cleanup; UTC one-shot Scheduled runtime triggering; causal correlation of a fresh Scheduled run via probe/message tags and latest-backing-run identifiers.
- Fresh causal probe `bridge-e2e-causal-20261006-0648`: Phase A #289 / run 37410888308 PASS; Phase B #290 / run 37411192345 completed pending; evidence reader #291 / run 37412211259; latest-run reader #292 / run 37412287909; Phase C #293 / run 37412472947 PASS cleanup/restoration.
- Causal evidence for the fresh run: run_advanced=true; last_run_time=2026-10-06T03:58:34.228534Z; latest_run_id=1bca803b-0287-473a-aa0e-e76dd1ccb37d; latest_run_created_at=2026-10-06T03:58:32.744319Z; both PROBE_ID and MESSAGE_ID tags present; automation_last_backing_run_failed=false; automation_latest_update_is_from_latest_run=true.
- The causally matched worker final answer states that the exact Library request file `bridge-e2e-causal-20261006-0648-request.json` was not found, therefore no result file was created.
- This supersedes the generation-31 uncertainty: the current fresh Scheduled run is now causally identified, and the failure boundary is inbound Library visibility/access from Scheduled runtime, not scheduling and not result-file verification.
- Desktop-side Library creation/read-back remains proven, so "file not found" means the Scheduled worker's usable Library/file surface is not equivalent to the Desktop-authenticated Library API surface, or it cannot discover newly created Library objects through the available runtime capability.
- The next minimal transport hypothesis is prompt-as-request + latest_backing_run-as-result, eliminating Library from the critical path while preserving no-composer/no-DOM-input operation.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No cookies, bearer tokens or credentials are persisted.
