# Manager beliefs

Manager generation: 21.
Updated: 2026-10-05 16:06 MSK

## Authority and accepted product state
- Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
- Product authority remains `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
- Manager-state authority remains `manager-state`.
- Canonical live Local Bridge transport baseline remains `ea074e06bd4e959106f49f57cad1ac731597dac3`.
- Accepted UI baseline remains `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.
- Production transport remains signed-in ChatGPT WebView2 + injected adapter + in-process native Local Bridge.
- Standard GitHub connector use is currently Owner-permitted until further notice.

## Runtime foundation
- Draft PR #22 / `dev/runtime-foundation-v1` / `3f5ff0fdda85165c38a977f2d29c7e893ecf3774` remains the integrated runtime-foundation candidate.
- It contains durable request/result handling, AUTO/ASK/DENY, Job Object/STOP, Tool Registry, repo/Git verification primitives and opt-in MCP.
- Owner signed-in runtime validation remains required before promotion.
- Intermittent result staged-but-not-auto-submitted remains open.

## Private transport research
- Scheduled Tasks are the control-plane candidate; ChatGPT Library/files are the data-plane candidate; local DurableRequestLedger remains the local crash-recovery journal.
- PR #24 = Scheduled Tasks metadata probe.
- PR #25 = combined Tasks + Library discovery/replay.
- PR #26 = divergent alternate v3 evidence branch.
- PR #27 / `private-transport-v3-70d3b29` was the installed user-facing v3 candidate.
- Owner live test of v3 on 2026-10-05 produced the same signature for scheduled, paused, library and storage: `Ok=false`, `Status=0`, `ElapsedMs=0`, `Error=null`, empty body hash.
- Root cause is a probe implementation bug, not evidence of backend rejection: WebView2 `ExecuteScriptAsync` returned the async IIFE Promise object before its `fetch` completed; the Promise serialized as `{}`, which deserialized into default C# values.
- PR #28 / `exp/chatgpt-private-transport-v4` fixes this by using an isolated per-request page-context async result slot and polling only until the Promise reaches a terminal result.
- The v4 fix applies both to `Private Read Proof` and captured-request replay.
- v4 head/release commit: `8b2123c5c4cdef4641101da5b325754f5169b4ad`; prerelease `private-transport-v4-8b2123c`.
- Release workflow `37313985424`: SUCCESS. Earlier Windows Build `37313889244` for the application fix: SUCCESS. A later full branch Windows Build was still running at persistence time and is not required to claim the release pipeline PASS.
- Exact updater from installed v3: `ChatGptDesktopLocalBridge-Update-from-private-transport-v3-70d3b29.exe`, 2,324,866 bytes, SHA-256 `1ed641e70317729d11fbc60dae939638e0cc49e84ca550f4b42eb010271b14f9`.
- Production `main` remains unchanged.

## Reliability rules
- A mutating timeout/connection loss after dispatch is `UNKNOWN_OUTCOME`, never blind retry.
- Reconcile writes by authoritative read-back before retry.
- ACK must follow durable result-file write.
- Do not expose arbitrary private/internal fetch as a model-facing primitive.
- Do not persist cookies, bearer tokens, OAuth tokens, sensitive headers, or hidden reasoning.
