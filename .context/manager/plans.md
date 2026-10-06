# Manager plans

Manager generation: 31.
Updated: 2026-10-06 05:32 MSK

## Active private-transport plan

1. Keep the five-second serialized network pacing invariant enforced in every probe/harness/client.
2. Treat #284 as a strong capability lead, not yet as causal proof for the latest one-shot run because its returned `created_at` predates that probe.
3. Extend the phased E2E evidence contract so Phase B, before cleanup, captures a bounded causal tuple: probe_id, worker_id, scheduled target, observed last_run_time/run advancement, backing-run id/created_at, role/kind/status metadata, and bounded content text.
4. Start a fresh probe_id with the proven UTC one-shot arm semantics:
   - Phase A: recovery snapshot -> request file -> one-shot arm -> authoritative read-back -> exit.
   - Phase B: one independent post-schedule observation; capture the backing-run causal tuple before any restoration; verify result file.
   - Phase C: restore worker and delete transport files regardless of outcome.
5. In that fresh run, explicitly determine whether the Scheduled worker can create a Library result directly from in-memory/JSON content.
6. If direct Library creation is unavailable in Scheduled runtime, identify and test the narrowest first-party ChatGPT return channel that does not require an external file intermediary or composer/DOM input.
7. On first complete Desktop -> worker -> Desktop PASS, add READY/ACK plus generation/seq/message_id fencing.
8. Implement production-oriented narrow clients from proven primitives.
9. Run forced interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests and 100+ round trips under the same pacing invariant.
