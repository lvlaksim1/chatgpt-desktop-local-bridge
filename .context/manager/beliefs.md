# Manager beliefs

Manager generation: 23.
Updated: 2026-10-05 16:31 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Runtime foundation remains draft PR #22; UI candidate 4c92f81 and ChatGPT-plan transport PR #23 remain separate validation tracks.
- Scheduled Tasks are the server-side control-plane candidate; ChatGPT Library/files are the server-side data-plane candidate; DurableRequestLedger remains local recovery state.
- Private Transport v5 live test PASSED on the Owner account: scheduled automations list, paused automations list, Library list, and Library storage usage all returned HTTP 200 through WebView page-context auth.
- This proves Desktop -> authenticated WebView page context -> /api/auth/session -> /backend-api/* read-plane works on the real signed-in account.
- v4's 401 was specifically an authorization-context gap; v5 closed that gap without persisting authorization material.
- Current user-facing private transport candidate is PR #29 / exp/chatgpt-private-transport-v5 / 95dd011593fd28b570831fc2995d26bef0691f27.
- Next gate is write-plane contract discovery from the current frontend: task pause/resume/schedule/arm and Library/file create/upload/process/read/delete.
- Mutating timeout/connection loss is UNKNOWN_OUTCOME; never blind retry. Reconcile by authoritative read-back.
- ACK must only follow durable result-file write.
- Do not expose arbitrary private fetch to the model and do not persist sensitive auth material.
