# Next actions

Updated: 2026-10-06 07:14 MSK

1. Implement a fresh crash-safe phased probe for prompt-as-request + latest_backing_run-as-result.
2. Keep the already-proven UTC one-shot scheduling and five-second network pacing unchanged.
3. Phase A: snapshot a safe paused worker, place bounded unique JSON request data directly in the worker prompt, arm once, read back, exit.
4. Phase B: after the scheduled time, perform one observation and require a causally tagged latest backing run whose final text exactly carries protocol, message_id, payload and ack.
5. Phase C: restore the borrowed task regardless of pass/failure.
6. If PASS, repeat with generation/seq/message_id fencing and duplicate/stale-response tests; do not reintroduce Library into the critical path.
7. If FAIL, inspect the causally matched final run and choose the next first-party in-product channel from evidence only.
8. Persist every durable finding immediately.
