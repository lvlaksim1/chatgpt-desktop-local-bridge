# Next actions

Updated: 2026-10-05 23:02 MSK

1. Use low-rate read-only runner evidence to compare the latest armed-worker timing fields against a known task that actually executes.
2. Identify whether next_run_times, timing_mode, target_time_utc or schedule serialization explains run_advanced=false.
3. Adjust the arm schedule only from observed evidence.
4. Start a fresh phased E2E probe; never reuse the completed probe state.
5. Run Phase A, wait without polling, then one Phase B observation.
6. If result verifies, run Phase C and then add READY/ACK/correlation fencing.
7. If still pending, reconcile/cleanup before the next hypothesis.
