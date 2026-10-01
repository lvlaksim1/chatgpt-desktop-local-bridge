# DEC-0006 — Single-file incremental update installers

Date: 2026-10-01
Status: accepted
Authority: Owner directive + verified CI/release evidence

## Decision

User-facing incremental upgrades are distributed as one executable:
`ChatGptDesktopLocalBridge-Update-from-dev-XXXXXXX.exe`.

ZIP delta packages and manual script launching are no longer the supported normal workflow.

The update EXE internally carries the delta manifest, changed payload, and rollback-capable updater. It validates the base, closes the application, applies only the delta, verifies hashes, rolls back on failure, and restarts the app.

## Legacy migration

The actually installed `dev-1d00606` cannot be validated by byte-identical reconstructed .NET DLLs. Its one-time migration validates Inno DisplayVersion `0.1.24.0` and stable content fingerprints instead.

After migration, `release-info.json` becomes the version identity and exact publish manifests are the baseline authority.

## Storage

Obsolete `Update-from-*.zip` release assets are removed by retention cleanup. Full Setup remains only for first installation and fallback.
