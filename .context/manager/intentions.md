# Manager intentions and commitments

Manager generation: 22.
Updated: 2026-10-05 16:20 MSK

## Runtime/UI
- Keep PR #22 unmerged until Owner runtime validation.
- Keep af6ac653 as accepted UI baseline until 4c92f81 passes Owner validation.

## Server-side transport R&D
Current live-test candidate: PR #29 / exp/chatgpt-private-transport-v5 / 95dd011593fd28b570831fc2995d26bef0691f27.

Commitments:
1. Keep production Local Bridge/DOM transport unchanged.
2. Treat v4 HTTP 401 as proof that routes are reachable but cookie-only requests are insufficient.
3. Keep same-session authorization context inside the authenticated page; do not persist sensitive auth material.
4. Retest Private Read Proof after v5 install before any mutation.
5. If v5 reads pass, capture current task and Library/file mutation contracts.
6. Preserve UNKNOWN_OUTCOME -> read-back -> reconcile for writes.
7. Require no-composer/no-DOM-input E2E before production consideration.
8. Run endurance/restart/duplicate/stale-ACK/navigation/relogin/network-loss/large-payload tests after first E2E.

## ChatGPT-plan transport
PR #23 remains isolated and Owner-gated.

## Operating directive
Standard GitHub connector use remains permitted until further notice.
