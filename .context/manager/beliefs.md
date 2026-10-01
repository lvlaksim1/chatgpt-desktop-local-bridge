# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main@4ed78c23fceddf628996be5a87a9847889c950e7`.
3. Manager-state authority: `manager-state`.
4. Current release: `dev-4ed78c2`.
5. Owner-installed baseline remains `dev-1d00606` unless the Owner reports a later successful update.
6. The first ZIP delta safely refused to apply because reconstructed `ChatGptDesktopLocalBridge.dll` bytes did not match the actually installed legacy DLL. No partial update remained.
7. The first single-EXE updater also failed safely. E2E investigation proved the root cause: the Inno-launched Windows PowerShell environment did not expose `Get-FileHash`, while the same updater logic executed directly under the runner shell succeeded.
8. Runtime update hashing no longer depends on `Get-FileHash`; SHA-256 is computed directly through `System.Security.Cryptography.SHA256`, compatible with the Windows PowerShell host used by the one-file updater.
9. A real Windows E2E test now installs legacy `dev-1d00606`, applies the generated single-file updater, verifies the target release marker, registers the uninstall wrapper, runs quiet uninstall, verifies application removal, and verifies preserved user data.
10. Current direct Owner migration asset: `dev-4ed78c2 / ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`.
    - size: 2,188,212 bytes
    - SHA-256: `5f4add91bb5988f3489666406e7a70b8138086dd973fcc780265e6b03aee8d0e`
11. Ordinary user-facing incremental updates are single EXE installers. ZIP delta packages are obsolete.
12. Delta updates validate the base, back up touched files, apply only changed files, verify target hashes, roll back on failure, write `update-last.log`, and preserve the WebView2 profile.
13. Starting from manifest-backed releases, exact `release-info.json` + `ChatGptDesktopLocalBridge-PublishManifest.json` identify the installed base.
14. The uninstall behavior is now delta-safe. A small `Support/Uninstall-Bridge.ps1` is shipped with application files and registered after full Setup and after verified delta updates.
15. Normal uninstall asks exactly `Удалить также настройки и рабочие данные?`. Answer No preserves `%LOCALAPPDATA%\ChatGptDesktopLocalBridge`; answer Yes deletes that data after the original application uninstaller succeeds. Quiet uninstall preserves data by default.
16. E2E verified the quiet-uninstall preservation path: the application was removed and a sentinel under the user-data directory remained.
17. WebView2 profile remains at `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2` and is outside application binaries.
18. BRIDGE-M1 remains active: after Owner updates successfully, confirm auth persistence, press Diagnostics, then prove READY and one `fs.read_text` round trip.
