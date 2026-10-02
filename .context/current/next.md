# Next actions

Updated: 2026-10-02 13:20 MSK

1. Monitor only the two currently running CI workflows for `dd26c48` and `9461fff`.
2. If both PASS:
   - submit one pc-runner-gateway request to update the Owner PC from `dev-85c714c` to `dev-31e823e`;
   - immediately submit one bounded M3 live regression after the update completes.
3. Accept M3 live PASS only when the real read succeeds and the ledger is `completed/delivered`, conversation-bound, with delivered payload retired.
4. Do not write further probe variants unless that single bounded regression returns a concrete failure.
5. Persist the live evidence and close the current M3 durable-foundation slice on PASS.
