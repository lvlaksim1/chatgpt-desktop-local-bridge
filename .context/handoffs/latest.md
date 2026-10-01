# Latest handoff

Updated: 2026-10-02 01:46 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 8.
Product authority: `main@4ed78c23fceddf628996be5a87a9847889c950e7`.
Current release: `dev-4ed78c2`.

Owner is assumed to remain on `dev-1d00606` because prior updater failure was fail-safe and no later successful Owner update has been reported.

Use only:
`ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`
SHA-256: `5f4add91bb5988f3489666406e7a70b8138086dd973fcc780265e6b03aee8d0e`.

The Windows E2E now reproduces legacy installation and successful one-file migration. It also verifies that the delta registers the uninstall wrapper and that quiet uninstall removes the program while preserving user data.

After Owner update succeeds: confirm authentication and run Diagnostics before Initialize Bridge.
