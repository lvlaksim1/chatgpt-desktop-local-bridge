# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main@f7688fbca03286d756d5f262808c8b40ec4f3952`.
3. Manager-state authority: `manager-state`.
4. Current release: `dev-f7688fb`.
5. Ordinary user-facing incremental updates are now single EXE installers named `ChatGptDesktopLocalBridge-Update-from-dev-XXXXXXX.exe`; ZIP delta packages are obsolete and removed by retention cleanup.
6. Current Owner-installed baseline remains `dev-1d00606`. The first ZIP delta correctly refused to apply because reconstructed `ChatGptDesktopLocalBridge.dll` bytes did not match the actually installed DLL. No partial update remained.
7. A direct one-step legacy migration EXE from `dev-1d00606` to `dev-f7688fb` is published. Size: 2,186,842 bytes. SHA-256: `32c0d5df41bdb999badcd91d0123ef06e41d6e8662f61a88d082ddf7e193537c`.
8. The legacy migration validates Inno Setup DisplayVersion `0.1.24.0` plus stable fingerprints of `Config/permissions.default.json` and `Web/bridge-adapter.js`; it intentionally does not require a reconstructed .NET DLL to be byte-identical.
9. The legacy migration then installs the current changed files, including `release-info.json`; later updates use exact release markers plus exact publish manifests.
10. The release pipeline smoke-tests the single-file update EXE with Inno Setup before merge/release. The real main run also built the legacy and exact-manifest update EXEs successfully.
11. Current direct legacy delta payload: 5 changed files, 0 deleted files, 239,408 uncompressed payload bytes; Inno single-file EXE overhead brings the distributed file to ~2.19 MB.
12. WebView2 profile remains outside application binaries at `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2` and is not modified by Setup or delta updater.
13. BRIDGE-M1 remains active: after updating to `dev-f7688fb`, Owner must confirm auth persistence, press Diagnostics, then proceed to READY and `fs.read_text` live proof.
