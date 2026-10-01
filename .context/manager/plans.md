# Manager plans

Manager generation: 7.
Product authority: `main@f7688fbca03286d756d5f262808c8b40ec4f3952`.
Current release: `dev-f7688fb`.
Owner installed baseline: `dev-1d00606`.

## Immediate BRIDGE-M1 path

1. Discard/ignore the failed ZIP delta.
2. Run `ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe` from `dev-f7688fb`.
3. The update must validate legacy base `0.1.24.0` + stable file fingerprints, close the app, backup touched files, apply five changed files, verify hashes, create `release-info.json`, restart the app, and roll back if any step fails.
4. Confirm ChatGPT remains authenticated.
5. Press Diagnostics before Initialize Bridge.
6. If adapter v2 is reported, Initialize Bridge and require READY.
7. Prove `fs.read_text` end-to-end.

## Future update policy

- Give the Owner one matching `Update-from-*.exe`, not ZIP archives.
- Full Setup remains first-install/fallback only.
- Future normal deltas use exact release-info + PublishManifest authority.
- Keep at most two installable dev releases and remove obsolete ZIP delta assets.
