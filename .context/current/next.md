# Next actions

Updated: 2026-10-06 07:35 MSK

1. Remove Library creation/list/download/delete from the successful prompt transport harness.
2. Add protocol generation, seq and message_id fields to request and response framing.
3. Require exact fresh-run correlation and reject stale/mismatched responses.
4. Run a fresh pure prompt Phase A -> one post-schedule Phase B -> Phase C cycle.
5. Repeat Phase B against the same completed run to prove idempotent read behavior.
6. Start a new generation/seq and verify the previous latest_backing_run is rejected as stale before the new run arrives.
7. Test controlled duplicate re-arm and result classification.
8. Persist findings, then proceed to READY/ACK and failure-recovery tests.
