# Manager plans

Manager generation: 26.
Updated: 2026-10-05 19:45 MSK

## Active
1. Complete runner request #240: Desktop creates request.json in Library, mutates/arms an existing bound Scheduled Task worker, waits for a distinct result.json, verifies message_id/payload/worker ACK, observes task run, restores task and deletes both files.
2. If PASS, implement explicit mailbox READY/ACK and generation/seq/message_id fencing.
3. Then implement narrow production-oriented clients for task state/schedule/prompt and Library file lifecycle.
4. Run restart, duplicate, stale-ACK, navigation/relogin, network-loss, cleanup and 100+ sequential round-trip campaign.
5. Classify transport as REJECT / CONTROL-PLANE ONLY / OPTIONAL / DEFAULT only after evidence.

Dedicated new-worker creation via target_thread_id remains a separate unresolved convenience path and is not required for first E2E because existing bound task mutation/restoration is proven.
