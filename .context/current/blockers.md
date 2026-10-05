# Current blockers and open risks

Updated: 2026-10-05 15:42 MSK

## Runtime foundation
PR #22 is CI/regression-proven but still lacks signed-in Owner runtime validation before merge to `main`.

## UI shell
Candidate `4c92f81` remains Owner-runtime-pending. Ordinary WebView2 remains required; CompositionControl and direct `ContextMenuTarget.LinkUri` remain rejected by prior live failures.

## Existing DOM/result transport
Intermittent result staging without automatic submit remains unresolved. This is one reason the server-side transport R&D remains valuable.

## Private Scheduled Tasks + Library transport
The current v3 candidate is compile/release-proven, not live-backend-proven on the current Owner account/frontend.

Still unproven:
- exact current task mutation bodies/semantics for pause/resume/schedule/one-shot arm;
- stable Library/file create-upload-process-read-delete sequence for transport files;
- account/workspace stale-context fencing strong enough for unattended writes;
- complete `request.json -> READY -> arm -> result.json -> ACK -> Desktop` round trip without composer/DOM input;
- safe recovery after timeout or ambiguous write outcome;
- restart/duplicate/stale-ACK/relogin/navigation/network-loss/large-payload/endurance behavior.

Writes must not use blind timeout retry. Unknown dispatch outcome requires authoritative read-back/reconciliation.

## Divergent v3 branches
PR #26 and PR #27 diverge from the same v2 base. Do not merge both wholesale. PR #27 is the current user-facing candidate; PR #26 is retained only as alternate evidence.

## MCP
MCP calls are behind Local Tool Runtime permissions/cancellation, but SDK-owned stdio server processes are not yet proven to share full Windows Job Object containment.

## ChatGPT-plan transport
PR #23 remains CI-only. Live OAuth/model/inference, protected rotating refresh-token storage, multi-account UX, tool round trip and usage-limit recovery remain unproven.
