# Manager intentions and commitments

Manager generation: 21.
Updated: 2026-10-05 16:06 MSK

## Runtime foundation
PR #22 remains unmerged. Preserve durable execution, permissions, Job Object/STOP, registry, repo/Git verification and MCP boundaries; require Owner runtime proof before promotion.

## UI shell
Accepted baseline remains `af6ac653`; candidate `4c92f81` remains Owner-runtime-pending. Do not reintroduce CompositionControl or direct `ContextMenuTarget.LinkUri` without new evidence.

## Server-side transport R&D
Current live-test candidate is now PR #28 / `exp/chatgpt-private-transport-v4` / `8b2123c5c4cdef4641101da5b325754f5169b4ad`.

Commitments:
1. Keep production Local Bridge/DOM transport unchanged.
2. Treat the v3 `Status=0 / 0 ms / null error` result as invalid probe evidence caused by Promise handling.
3. Retest the same `Private Read Proof` only after v4 installation.
4. If v4 returns real HTTP results, use those results to decide whether missing auth/account headers or endpoint drift is the next issue.
5. Only after read-plane proof capture exact task/file mutation shapes.
6. Preserve `UNKNOWN_OUTCOME -> read-back -> reconcile` for writes.
7. Require full `request.json -> READY -> arm -> result.json -> ACK -> Desktop` with no composer/DOM input before promotion.
8. Run restart/duplicate/stale-ACK/navigation/relogin/network-loss/large-payload/100+ round-trip tests after first E2E.
9. Do not merge divergent PR #26/#27 wholesale into v4; reuse only individually proven pieces.

## ChatGPT-plan transport
PR #23 remains isolated and Owner-gated.

## Operating directive
Standard GitHub connector use remains permitted until further notice. Never store credentials, cookies, tokens or hidden reasoning in Git.
