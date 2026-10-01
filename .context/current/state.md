# Current state

Updated: 2026-10-01 20:00 MSK

## Governance
- manager: `chatgpt-desktop-local-bridge-project-manager`
- manager generation: 6
- manager-state authority: `manager-state`
- product authority: `main@a43d23653a056defffb987c342312b204d357012`
- execution status: ACTIVE / BRIDGE-M1 live validation

## Update system
- ordinary updates: compact delta ZIPs
- full Setup: first install / fallback
- updater: exact base-hash verification + backup + apply + target-hash verification + rollback + restart
- WebView2 profile is outside updater scope
- first manifest-backed release: `dev-a43d236`
- exact release manifest asset: `ChatGptDesktopLocalBridge-PublishManifest.json`

## Current Owner migration
Installed: `dev-1d00606`.

Available compact path:
- `dev-1d00606 -> dev-9c8b8b7`: 135,943-byte ZIP
- `dev-9c8b8b7 -> dev-a43d236`: 133,678-byte ZIP

Total download is about 270 KB instead of another ~51 MB full Setup.

## BRIDGE-M1
Document-start adapter fix is present. After completing the compact migration, rerun Diagnostics. Expected healthy evidence begins with adapter v2.
