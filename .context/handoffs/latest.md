# Latest handoff

Updated: 2026-10-05 15:42 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 20.

## Authority

- Product authority: `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
- Manager-state authority: `manager-state`.
- Canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
- Accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.
- Production transport remains signed-in ChatGPT WebView2 + in-process Local Bridge.

## Runtime foundation

Draft PR #22 / `dev/runtime-foundation-v1` / `3f5ff0f`.
Integrated durable execution, permissions, Job Object/STOP, Tool Registry, repo/Git verification primitives and MCP. CI/regression proof exists; Owner signed-in runtime validation remains pending.

## Server-side transport research

The research direction is now:
- Scheduled Tasks = control plane;
- ChatGPT Library/files = data plane;
- local DurableRequestLedger = separate local crash-recovery journal.

Progression:
1. PR #24 / `task-probe-49fb895`: Scheduled Tasks metadata discovery.
2. PR #25 / `scheduled-file-probe-6bb827b`: combined Tasks + Library discovery and same-session replay.
3. PR #26 / `private-transport-probe-dd472e4`: alternate request-bound v3 implementation.
4. PR #27 / `private-transport-v3-70d3b29`: current user-facing v3 candidate.

PR #27 head: `70d3b2900cd72b2892dd4c75d000df4d2938e9be`.
Windows Build `37166260285`: PASS.
Release workflow `37166255838`: PASS.
Updater from `scheduled-file-probe-6bb827b`: 2,323,481 bytes, SHA-256 `ccc9f17b560b18df27131184e6b2967782dc3f9b18d4f5adc940f057d3573595`.

PR #27 is not production-approved. The next proof is live current-account validation of Tasks/Library routes, mutating request shapes and read-back semantics, followed by one complete `request.json -> READY -> arm -> result.json -> ACK -> Desktop` cycle with no composer/DOM input.

Mutation reliability rule: timeout after dispatch is `UNKNOWN_OUTCOME`; reconcile by authoritative read-back before retry. ACK must only follow durable result-file write.

PR #26 and PR #27 are divergent alternatives. Do not merge both mechanically. `exp/chatgpt-private-transport-v4` currently points to the same v3 commit and has no independent authority.

## Other active tracks

- UI candidate `4c92f81`: Owner runtime validation pending.
- Official ChatGPT-plan transport PR #23 / `f2a3056`: CI PASS, live OAuth/model/inference pending.
- Existing DOM result auto-submit intermittency remains open.

## Operating directive

Standard GitHub connector use is currently permitted until further notice.
