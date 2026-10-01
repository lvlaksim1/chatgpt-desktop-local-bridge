# DEC-0007 — Windows PowerShell-compatible updater and delta-safe uninstall

Date: 2026-10-02
Status: accepted
Authority: verified E2E evidence + Owner uninstall requirement

## Updater compatibility

The one-file update wrapper launches Windows PowerShell. Runtime verification logic must therefore avoid assuming optional cmdlets are present in that host.

SHA-256 verification is implemented directly through `System.Security.Cryptography.SHA256` instead of `Get-FileHash`.

A release is not considered a supported legacy migration until CI has:
1. installed legacy `dev-1d00606`;
2. executed the generated one-file updater;
3. verified the target `release-info.json`.

## Delta-safe uninstall

Uninstall behavior must not depend solely on Inno's generated `unins000.exe`, because ordinary delta updates do not replace that generated uninstaller.

A small application-shipped uninstall wrapper is therefore authoritative for normal uninstall invocation. Full Setup and delta updater register it in the Windows uninstall entry.

Normal behavior:
- prompt: `Удалить также настройки и рабочие данные?`
- No: preserve `%LOCALAPPDATA%\ChatGptDesktopLocalBridge`
- Yes: delete that directory after successful application uninstall
- quiet uninstall: preserve user data by default

CI verifies that a legacy delta installs/registers the wrapper and that quiet uninstall removes program files while preserving sentinel user data.
