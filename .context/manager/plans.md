# Manager plans

Manager generation: 33.
Updated: 2026-10-06 07:35 MSK

## Active private-transport plan

1. Keep the five-second serialized network pacing invariant.
2. Refactor the phased harness so prompt transport no longer creates or lists Library files at all.
3. Define a compact framed request/response schema carrying protocol, generation, seq, message_id, payload and ack.
4. Require Phase B to accept only a latest_backing_run that is fresh for the armed run and whose correlation fields exactly match the request.
5. Run a second clean prompt E2E on the pure no-Library harness.
6. Run duplicate/stale tests:
   - repeated Phase B read of one run must be idempotent;
   - a stale prior latest_backing_run must be rejected for a new message_id/seq;
   - re-arm behavior must not silently accept a duplicate result as a new generation.
7. Add crash-safe READY/ACK state only after those fencing tests pass.
8. Then run relogin/navigation/network-loss/orphan cleanup and 100+ round trips before considering production integration.
