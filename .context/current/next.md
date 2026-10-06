# Next actions

Updated: 2026-10-06 04:30 MSK

1. Read the latest backing run for the worker used by `bridge-e2e-oneshot-20261006-0323`.
2. Extract bounded execution evidence only; do not expose or persist credentials/auth material.
3. Determine why the Scheduled run completed without creating the expected Library result file.
4. Adjust the worker prompt/contract only from observed evidence; keep the proven UTC one-shot scheduling semantics unchanged.
5. Start a fresh probe_id for the next phased E2E; never reuse the completed probe state.
6. Run Phase A, wait without polling, then one Phase B observation.
7. Run Phase C cleanup after the observation regardless of pass/pending outcome.
8. If result verifies, add READY/ACK/correlation fencing; otherwise reconcile before the next hypothesis.
