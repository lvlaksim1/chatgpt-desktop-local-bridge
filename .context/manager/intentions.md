# Manager intentions and commitments

Manager generation: 26.
Updated: 2026-10-05 19:45 MSK

Current experimentation branch: exp/runner-private-transport-control-plane / draft PR #30.

Proven:
- authenticated read-plane;
- Pause + Resume;
- Schedule create/update/remove;
- arm/rearm on an existing bound task with restoration;
- prompt mutation with restoration;
- Library upload/process/exact-download/rename/delete.

Current active gate:
- runner request #240 executes the first Desktop Scheduled Tasks + Library E2E using a unique request file, temporary worker prompt/schedule on an existing bound paused task, result-file verification, run observation, cleanup and exact task restoration.

Commitments:
1. Do not ask Owner for routine manual testing while runner can perform it.
2. Keep all experiments reversible and clean disposable files/tasks.
3. Treat failed/ambiguous writes with read-back before retry.
4. If E2E passes, next add explicit mailbox ACK/fencing and then endurance.
5. If E2E fails, diagnose the narrow failing boundary without weakening safety or falling back to DOM/composer transport.
