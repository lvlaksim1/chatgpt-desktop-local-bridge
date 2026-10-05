# Current state

Updated: 2026-10-05 15:42 MSK

- manager generation: 20
- product authority: `main`
- current product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- manager-state authority: `manager-state`
- canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`
- accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`
- UI candidate: `4c92f81d46b77f964b8e99fe25439058b9b835a1`, still Owner-runtime-pending
- runtime foundation: draft PR #22, branch `dev/runtime-foundation-v1`, head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`; live Owner validation pending
- official ChatGPT-plan transport: draft PR #23, head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`; CI PASS, live OAuth/inference pending
- Scheduled Tasks metadata probe: draft PR #24, release `task-probe-49fb895`
- Scheduled Tasks + Library probe v2: draft PR #25, head `6bb827b007111c225ba17cf8c3900ddc86ae4b1a`, release `scheduled-file-probe-6bb827b`
- current user-facing private transport R&D candidate: draft PR #27, branch `exp/chatgpt-private-transport-v3`, head `70d3b2900cd72b2892dd4c75d000df4d2938e9be`
- PR #27 Windows Build run `37166260285`: SUCCESS
- PR #27 release run `37166255838`: SUCCESS
- PR #27 prerelease: `private-transport-v3-70d3b29`
- PR #27 incremental updater from `scheduled-file-probe-6bb827b`: `ChatGptDesktopLocalBridge-Update-from-scheduled-file-probe-6bb827b.exe`, 2,323,481 bytes, SHA-256 `ccc9f17b560b18df27131184e6b2967782dc3f9b18d4f5adc940f057d3573595`
- alternate divergent v3 exists as draft PR #26 / `exp/private-transport-probe-v3` / `dd472e44077e962ddb4b96e21d65de14ddb4b183`; treat as evidence/alternate implementation, not current authority
- `exp/chatgpt-private-transport-v4` currently has no unique commit and points to the v3 head; ignore as an active stage
- production/default Local Bridge transport remains unchanged on `main`
- current private transport live gate: validate actual current Tasks/Library backend behavior and complete a no-composer/no-DOM-input file+mailbox E2E
- current Owner directive permits standard GitHub connector use until further notice
