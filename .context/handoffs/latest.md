# Latest handoff

Updated: 2026-10-05 16:06 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 21.

Product `main` remains `6e2a0b54b727c5474bad40ac038f727a39cceb8d`; no private transport experiment is production-promoted.

## Current private transport event
Owner installed v3 and ran `Private Read Proof`. All four results had `Ok=false`, `Status=0`, `ElapsedMs=0`, empty response and `Error=null`.

Repository inspection identified the root cause: v3 used an async IIFE directly as the expression passed to WebView2 `ExecuteScriptAsync`. The API returned the Promise object before `fetch` completed; it serialized as `{}`, then C# deserialized default values. Therefore the v3 live result is not evidence of backend rejection.

## v4 fix
Draft PR #28 / branch `exp/chatgpt-private-transport-v4`.
Head/release commit: `8b2123c5c4cdef4641101da5b325754f5169b4ad`.
The fix adds an isolated per-request page-context async result slot and waits for a terminal Promise result before C# deserialization. Applied to Private Read Proof and replay.

Release `private-transport-v4-8b2123c`.
Release workflow `37313985424`: PASS.
Exact updater from installed v3:
`ChatGptDesktopLocalBridge-Update-from-private-transport-v3-70d3b29.exe`
2,324,866 bytes
SHA-256 `1ed641e70317729d11fbc60dae939638e0cc49e84ca550f4b42eb010271b14f9`.

Next action: install v4, rerun only Private Read Proof, then analyze the real HTTP result before any mutations.

Other active tracks remain PR #22 runtime foundation, UI candidate `4c92f81`, and PR #23 official ChatGPT-plan transport.
