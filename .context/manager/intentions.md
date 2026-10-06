# Manager intentions and commitments

Manager generation: 32.
Updated: 2026-10-06 07:14 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.
Verified live branch head: fe87cab8cddbcb2b3de9befe367eea2220b4ef46.

Proven:
- authenticated private read-plane;
- Pause/Resume;
- Schedule create/update/remove;
- existing-task arm/rearm with restoration;
- existing-task prompt mutation with restoration;
- complete disposable Library lifecycle from Desktop with exact byte read-back and cleanup;
- Scheduled runtime trigger using a UTC one-shot VEVENT;
- causal identification of a fresh Scheduled backing run using unique PROBE_ID/MESSAGE_ID tags and latest-run metadata.

Fresh causal E2E:
- Phase A #289 / run 37410888308: PASS;
- Phase B #290 / run 37411192345: pending/no result file;
- ledger evidence #291 / run 37412211259: run_advanced=true, last_run_time=2026-10-06T03:58:34.228534Z, latest_run_created_at=2026-10-06T03:58:32.744319Z, probe/message tags both true, latest update confirmed as latest run;
- latest-run evidence #292 / run 37412287909: the causally matched worker says the exact request file was not found in Library, so it created no result file;
- Phase C #293 / run 37412472947: PASS cleanup/restoration.

Commitments:
1. Treat Scheduled triggering and run correlation as proven; do not reopen those layers without contradictory evidence.
2. Treat worker-side Library request discovery as the current failed primitive: Desktop can create/read the object, but the Scheduled worker could not find it.
3. Do not claim that all Library access is impossible; only the tested discovery/read path for this fresh file is disproven.
4. Test the simpler in-product transport next: request JSON embedded in the task prompt, response JSON encoded in latest_backing_run final text.
5. Keep the payload bounded and explicitly correlated by probe_id/message_id/generation/seq.
6. Restore the borrowed task after every experiment and preserve the five-second serialized pacing invariant.
7. Keep main unchanged until promotion evidence exists.
