# Current state

Updated: 2026-10-05 16:06 MSK

- manager generation: 21
- product authority: `main`
- product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- manager-state authority: `manager-state`
- production/default Local Bridge transport unchanged
- accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`
- runtime foundation: draft PR #22 / `3f5ff0f`; Owner runtime proof pending
- ChatGPT-plan transport: draft PR #23 / `f2a3056`; live OAuth/inference pending
- current private transport live-test candidate: draft PR #28 / `exp/chatgpt-private-transport-v4`
- v4 head/release commit: `8b2123c5c4cdef4641101da5b325754f5169b4ad`
- prerelease: `private-transport-v4-8b2123c`
- release workflow `37313985424`: SUCCESS
- v4 exact updater from installed v3: `ChatGptDesktopLocalBridge-Update-from-private-transport-v3-70d3b29.exe`
- updater size: 2,324,866 bytes
- updater SHA-256: `1ed641e70317729d11fbc60dae939638e0cc49e84ca550f4b42eb010271b14f9`
- v3 live read proof result was invalid due to async Promise handling bug: identical default `Status=0 / ElapsedMs=0 / Error=null` values were produced before fetch completion
- v4 fixes Promise completion for Private Read Proof and replay using isolated page-context async result slots
- next gate: install v4 and repeat Private Read Proof
- current Owner directive permits standard GitHub connector use
