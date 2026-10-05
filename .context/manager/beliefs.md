# Manager beliefs

Manager generation: 22.
Updated: 2026-10-05 16:20 MSK

## Authority
- Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
- Product authority remains `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
- Manager-state authority remains `manager-state`.
- Canonical live Local Bridge transport baseline remains `ea074e06bd4e959106f49f57cad1ac731597dac3`.
- Accepted UI baseline remains `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.
- Production transport remains signed-in ChatGPT WebView2 + injected adapter + in-process native Local Bridge.
- Standard GitHub connector use is currently Owner-permitted until further notice.

## Active runtime tracks
- Runtime foundation: draft PR #22 / `3f5ff0f`; Owner signed-in runtime validation pending.
- UI recovery candidate: `4c92f81`; Owner runtime validation pending.
- Official ChatGPT-plan transport: draft PR #23 / `f2a3056`; live OAuth/model/inference pending.

## Private transport research
- Scheduled Tasks = control-plane candidate.
- ChatGPT Library/files = data-plane candidate.
- Local DurableRequestLedger remains the separate local crash-recovery journal.
- v3 live proof was invalid because WebView2 `ExecuteScriptAsync` returned a Promise object before fetch completion.
- v4 fixed Promise-await semantics. Owner live v4 proof then produced real HTTP 401 for scheduled, paused, library and storage routes, with nonzero elapsed time and backend JSON response shapes.
- Therefore the current blocker is authorization/context, not route reachability and not Promise handling.
- External working reference confirms the page can call `/api/auth/session`, obtain the current access token in page memory, and use `Authorization: Bearer ...`; Scheduled Tasks also bind to current workspace/account context.
- PR #29 / `exp/chatgpt-private-transport-v5` adds same-session auth acquisition entirely inside page context. The bearer and account id are never returned to C# and are never persisted.
- v5 release commit: `95dd011593fd28b570831fc2995d26bef0691f27`.
- v5 prerelease: `private-transport-v5-95dd011`.
- Exact updater from installed v4: `ChatGptDesktopLocalBridge-Update-from-private-transport-v4-8b2123c.exe`, 2,325,233 bytes, SHA-256 `7daea13be16f544662926af8aa4e12f45961be371c7deb8be156b75ae47e9b9b`.
- Production `main` remains unchanged.

## Reliability and security
- Mutating timeout/connection loss after dispatch is `UNKNOWN_OUTCOME`, never blind retry.
- Reconcile writes by authoritative read-back.
- ACK must follow durable result-file write.
- Do not expose arbitrary private fetch as a model-facing primitive.
- Do not persist cookies, bearer tokens, OAuth tokens, sensitive headers or hidden reasoning.
