# Current blockers and open risks

Updated: 2026-10-05 16:31 MSK

## Private transport
Read-plane is no longer blocked.

Still unproven:
- exact task pause/resume/schedule/one-shot arm mutation contracts;
- authoritative read-back for each task mutation;
- Library/file create-upload-process-read-replace-delete lifecycle;
- account/workspace stale-context fencing strong enough for unattended writes;
- ambiguous write recovery;
- complete request.json -> READY -> arm -> result.json -> ACK -> Desktop E2E;
- restart/duplicate/stale-ACK/navigation/relogin/network-loss/large-payload/endurance behavior.

## Other tracks
Existing DOM result auto-submit intermittency remains open.
PR #22, UI candidate 4c92f81 and PR #23 still need their separate Owner live validations.
