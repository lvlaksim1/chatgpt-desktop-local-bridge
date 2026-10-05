# Current state

Updated: 2026-10-05 16:20 MSK

- manager generation: 22
- product authority: main
- product head: 6e2a0b54b727c5474bad40ac038f727a39cceb8d
- manager-state authority: manager-state
- production/default Local Bridge transport unchanged
- accepted UI baseline: 0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053
- runtime foundation: draft PR #22 / 3f5ff0f; Owner runtime proof pending
- ChatGPT-plan transport: draft PR #23 / f2a3056; live OAuth/inference pending
- v4 live Private Read Proof: real HTTP 401 on scheduled, paused, library and storage routes
- v4 proved Promise-await fix and backend reachability; current issue is authorization/context
- current private transport candidate: draft PR #29 / exp/chatgpt-private-transport-v5
- v5 head/release commit: 95dd011593fd28b570831fc2995d26bef0691f27
- prerelease: private-transport-v5-95dd011
- exact updater from installed v4: ChatGptDesktopLocalBridge-Update-from-private-transport-v4-8b2123c.exe
- updater size: 2,325,233 bytes
- updater SHA-256: 7daea13be16f544662926af8aa4e12f45961be371c7deb8be156b75ae47e9b9b
- v5 keeps same-session authorization context inside the page and does not persist sensitive auth material
- next gate: install v5 and rerun Private Read Proof
