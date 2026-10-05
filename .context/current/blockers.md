# Current blockers and open risks

Updated: 2026-10-05 17:52 MSK

No blocker remains for read-plane, Pause, Resume, or autonomous runner control of those state transitions.

Still unproven:
- Task Schedule mutation contract and safe restoration;
- one-shot arm/rearm contract;
- Library/file create-upload-process-read-replace-delete lifecycle;
- strong account/workspace stale-context fencing for unattended writes;
- ambiguous write recovery under forced network loss;
- complete no-DOM E2E and endurance matrix.

Runner scripts must not leave long-lived child GUI processes inside the gateway job tree.
