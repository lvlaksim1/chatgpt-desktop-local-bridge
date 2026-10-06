# Manager intentions and commitments

Manager generation: 33.
Updated: 2026-10-06 07:35 MSK

Current experimental line: PR #30 / exp/runner-private-transport-control-plane.
Prompt transport test commit: 4e5843209b2b67d12750594256047a62cfc21cf5.

Proven:
- authenticated private read-plane;
- Pause/Resume;
- schedule create/update/remove;
- existing-task arm/rearm and prompt mutation with restoration;
- Desktop-side Library lifecycle;
- UTC one-shot Scheduled runtime trigger;
- causal fresh-run correlation;
- bounded prompt-as-request + latest_backing_run-as-result round trip.

Prompt transport evidence:
- Phase A #294 / run 37413075306 PASS;
- Phase B #295 / run 37413346604 Project PASS;
- Phase C #296 / run 37414107982 PASS cleanup/restoration;
- ledger #297 / run 37414262277: stage=transport_verified, run_advanced=true, fresh latest run tagged by probe/message, result_found=false, result_verified=false, project_status=pass.

Commitments:
1. Treat the prompt transport primitive as proven only for the bounded tested payload and exact one-shot path.
2. Do not claim production readiness yet.
3. Remove Library from the transport critical path in the next harness revision.
4. Add generation, seq and message_id to both request and response framing.
5. Reject stale/mismatched latest_backing_run responses before accepting a result.
6. Test duplicate observation and duplicate execution behavior explicitly.
7. Restore borrowed tasks after every experiment and preserve the five-second serialized pacing invariant.
8. Keep main unchanged until promotion evidence exists.
