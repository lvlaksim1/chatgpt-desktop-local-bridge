# Manager intentions and commitments

Manager generation: 25.
Updated: 2026-10-05 17:52 MSK

## Runner operating mode
- Default to pc-runner-gateway for live Windows tests.
- Do not ask the Owner to click UI or return screenshots when a bounded runner/CDP/UIAutomation test can collect the same evidence.
- Keep runner scripts exact-SHA pinned, allowlisted, bounded, state-restoring and evidence-producing.
- Separate diagnostic app lifecycle from normal app restoration; restore normal GUI through a separate Task Scheduler/InteractiveToken task.

## Private transport evidence
- Read-plane PASS on v5.
- Pause mutation PASS.
- Runner control-plane cycle #208 PASS proves Resume as well as Pause and original-state restoration.
- App restore #210 PASS.

## Next
1. Runner-discover schedule mutation contract.
2. Runner-discover one-shot arm/rearm contract.
3. Runner-discover Library/file create-upload-process-read-replace-delete lifecycle.
4. Implement narrow clients and UNKNOWN_OUTCOME reconciliation.
5. Execute first full request.json -> READY -> arm -> result.json -> ACK -> Desktop E2E.
