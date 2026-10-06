# Current state

Updated: 2026-10-06 07:35 MSK

- manager generation: 33
- product main: 6e2a0b54b727c5474bad40ac038f727a39cceb8d
- production Local Bridge: unchanged
- research line: PR #30 / exp/runner-private-transport-control-plane
- prompt transport test commit: 4e5843209b2b67d12750594256047a62cfc21cf5
- five-second serialized network pacing: ACTIVE
- authenticated read-plane: PASS
- Pause/Resume: PASS
- schedule mutation: PASS
- prompt mutation: PASS
- Desktop-side Library lifecycle: PASS
- UTC one-shot Scheduled trigger: PROVEN
- causal run correlation: PROVEN
- Library request path to Scheduled worker: FAILED for the tested fresh-file discovery path
- prompt-as-request + latest_backing_run-as-result: FIRST FULL PASS
- Phase A #294 / run 37413075306: PASS
- Phase B #295 / run 37413346604: Project PASS
- Phase C #296 / run 37414107982: PASS cleanup/restoration
- ledger #297 / run 37414262277: project_status=pass, stage=transport_verified, run_advanced=true, result_found=false, result_verified=false, fresh latest run and both correlation tags present
- current gate: remove incidental Library work, add generation/seq fencing, and repeat on a pure prompt transport harness
