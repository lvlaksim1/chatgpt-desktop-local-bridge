# Current blockers and open risks

Updated: 2026-10-05 16:20 MSK

## Private transport
v4 returns real backend responses. All four narrow reads returned HTTP 401, so cookie-only requests are insufficient.

v5 tests whether page-owned current-session authorization context is sufficient. Until Owner reruns v5, remaining request-context requirements are unknown.

After read-plane proof, still unproven:
- task mutation bodies and one-shot arm semantics;
- Library/file upload/process/read/delete lifecycle;
- strong account/workspace stale-context fencing for unattended writes;
- ambiguous-write recovery;
- full no-DOM E2E;
- restart/duplicate/stale-ACK/navigation/relogin/network-loss/large-payload/endurance behavior.

## Existing transport
Intermittent result staging without auto-submit remains open.

## Runtime/UI/MCP
PR #22 and UI candidate 4c92f81 still need Owner runtime validation. MCP stdio child-process containment remains incomplete.

## ChatGPT-plan
PR #23 remains CI-only.
