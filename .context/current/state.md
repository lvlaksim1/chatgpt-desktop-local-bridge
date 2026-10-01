# Current state

Updated: 2026-10-02 01:46 MSK

- manager generation: 8
- product authority: `main@4ed78c23fceddf628996be5a87a9847889c950e7`
- current release: `dev-4ed78c2`
- Owner installed baseline: `dev-1d00606` unless Owner reports otherwise
- old ZIP delta: obsolete; safely rejected
- old single-EXE updater: obsolete; failed safely because Inno-launched Windows PowerShell lacked `Get-FileHash`
- root cause: confirmed by Windows E2E logs
- fix: direct .NET SHA-256 implementation
- current migration EXE: `ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`
- size: 2,188,212 bytes
- SHA-256: `5f4add91bb5988f3489666406e7a70b8138086dd973fcc780265e6b03aee8d0e`
- E2E legacy install -> current Update.exe: PASS
- delta-safe uninstall wrapper: implemented and registered by full Setup and delta updater
- quiet uninstall E2E: program removed; user-data sentinel preserved
- normal uninstall prompt: `Удалить также настройки и рабочие данные?`
- WebView2 auth profile remains outside updater scope
- BRIDGE-M1 live validation remains open
