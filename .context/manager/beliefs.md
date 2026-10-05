# Manager beliefs

Manager generation: 20.
Updated: 2026-10-05 15:42 MSK

## Authority and accepted product state

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority remains `main`; current verified head is `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
3. Manager-state authority remains `manager-state`.
4. Canonical live Local Bridge transport baseline remains `ea074e06bd4e959106f49f57cad1ac731597dac3`.
5. BRIDGE-M1 and BRIDGE-M2 are CLOSED.
6. Owner-accepted UI recovery baseline remains `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`. Candidate `4c92f81d46b77f964b8e99fe25439058b9b835a1` is CI-proven but still not Owner-runtime-promoted.
7. Production transport remains ordinary signed-in `chatgpt.com` inside WebView2 plus injected adapter and in-process native C# Local Bridge. No alternative transport has been approved as production/default.
8. The standard GitHub connector is currently permitted by Owner until further notice. This supersedes the older rule that connector use was exceptional.

## Runtime foundation

9. `dev/runtime-foundation-v1` / draft PR #22 / head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774` is the current integrated runtime-foundation candidate.
10. It contains durable request/result behavior, reconciled write/process tools, real AUTO/ASK/DENY enforcement, Windows Job Object containment, generic STOP cancellation, metadata-backed Tool Registry, bounded repo tools, Git checkpoint/verification primitives, and opt-in MCP stdio integration.
11. Windows CI proved build/runtime/repo regression behavior, including temporary-Git status/diff/map/checkpoint/verify and Job Object STOP. Owner signed-in runtime validation is still required before merge to `main`.
12. The known staged-but-not-auto-submitted result weakness remains an open transport reliability issue.

## Transport research

13. Official ChatGPT-plan OAuth/Responses transport remains isolated in `exp/chatgpt-plan-transport` / draft PR #23 / head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`. It is CI-proven but still requires live Owner OAuth/model/inference proof.
14. Scheduled Tasks + Library research established the working design hypothesis: Scheduled Tasks are the server-side control plane and ChatGPT Library/files are the server-side data plane. The target transport is `Desktop -> request file -> READY/arm -> Scheduled runtime -> result file -> ACK -> Desktop`, without composer/DOM message injection in the critical path.
15. `exp/scheduled-task-metadata-probe` / PR #24 proved the first Desktop diagnostic layer; release `task-probe-49fb895`.
16. `exp/scheduled-file-transport-probe-v2` / PR #25 / head `6bb827b007111c225ba17cf8c3900ddc86ae4b1a` added combined Scheduled Tasks + Library discovery and human-gated same-session page-context replay; release `scheduled-file-probe-6bb827b`.
17. Two parallel Private Transport v3 implementations exist from the same v2 base:
    - PR #26 / `exp/private-transport-probe-v3` / head `dd472e44077e962ddb4b96e21d65de14ddb4b183`;
    - PR #27 / `exp/chatgpt-private-transport-v3` / head `70d3b2900cd72b2892dd4c75d000df4d2938e9be`.
18. The current user-facing candidate is PR #27 because it is the most recent branch/release explicitly delivered in this chat. PR #26 is retained as an alternate earlier implementation/evidence branch and must not be treated as a second current authority.
19. PR #27 is draft, mergeable/clean, Windows Build run `37166260285` PASS and release run `37166255838` PASS. Prerelease: `private-transport-v3-70d3b29`.
20. PR #27 adds a narrow private transport layer over same-session page-context requests, request/document/navigation binding, read proof and human-gated mutation replay with explicit `UNKNOWN_OUTCOME` semantics. It does not replace production Local Bridge.
21. Branch `exp/chatgpt-private-transport-v4` currently points to the same commit as v3 and contains no unique work. Treat it as non-authoritative unless it later receives a distinct verified commit.
22. Current research principle for writes: timeout/connection loss after dispatch is `UNKNOWN_OUTCOME`, not automatic retry. Reconcile by authoritative read-back before deciding whether retry is safe.
23. Current research principle for server-side transport: ACK must follow durable result-file write; local `DurableRequestLedger` remains a separate local crash-recovery journal rather than being replaced by Tasks/Library state.

## Safety and persistence

24. Do not persist credentials, cookies, bearer tokens, OAuth access/refresh/ID tokens, hidden reasoning, or raw sensitive request headers in Git or diagnostic logs.
25. Internal/private backend hypotheses are R&D evidence. Do not generalize them into an arbitrary model-facing fetch primitive; expose only narrow capability methods after live validation.
26. CI/build success is not sufficient evidence for signed-in WebView behavior, current private backend shapes, authentication continuity, or destructive/mutating semantics.
