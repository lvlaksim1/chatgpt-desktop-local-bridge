# Latest handoff

Updated: 2026-10-01 20:00 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 6.
Product authority: `main@a43d23653a056defffb987c342312b204d357012`.

## Incremental updates completed
The project now publishes compact SHA-verified delta update ZIPs with rollback and keeps the full Setup as fallback.

`dev-a43d236` is the first release containing an exact `ChatGptDesktopLocalBridge-PublishManifest.json`. Future delta generation prefers this exact release evidence over reconstructed builds.

## Current Owner path
Owner is on `dev-1d00606`.
Use:
1. `dev-9c8b8b7 / Update-from-dev-1d00606` (~136 KB)
2. `dev-a43d236 / Update-from-dev-9c8b8b7` (~134 KB)

Then rerun Diagnostics. Do not claim BRIDGE-M1 success until READY and `fs.read_text` round trip are proven.
