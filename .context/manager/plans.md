# Manager plans

Manager generation: 32.
Updated: 2026-10-06 07:14 MSK

## Active private-transport plan

1. Keep the five-second serialized network pacing invariant enforced in every probe/harness/client.
2. Stop spending experiments on Scheduled-trigger diagnosis; UTC one-shot triggering and causal run identification are proven.
3. Treat the Library-file transport as failed at the inbound worker visibility step for the tested path: a fresh request file was Desktop-readable but absent to the causally matched Scheduled worker.
4. Implement a minimal prompt transport probe that uses no Library data-plane:
   - Phase A: snapshot a safe paused worker; encode a small unique request JSON directly in its prompt; arm the proven UTC one-shot schedule; authoritative read-back; exit.
   - Phase B: one post-schedule observation; require a causally tagged latest_backing_run and exact echoed protocol/message_id/payload/ack in final text.
   - Phase C: restore the borrowed worker.
5. If prompt -> Scheduled run -> latest_backing_run passes, repeat it with generation/seq/message_id fencing and duplicate/stale-response checks before adding any larger payload mechanism.
6. If prompt transport fails, inspect the exact causally matched run and only then evaluate another first-party in-product channel.
7. Keep Library lifecycle code as a separately proven Desktop-side primitive, but remove it from the transport critical path unless a future worker-side capability is independently proven.
8. On first complete Desktop -> worker -> Desktop PASS, add READY/ACK plus generation/seq/message_id fencing.
9. Run forced interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests and 100+ round trips under the same pacing invariant.
