# Manager beliefs

## Active verified beliefs

1. The product repository is `lvlaksim1/chatgpt-desktop-local-bridge`.
   - source: live GitHub repository state
   - authority: verified-repository

2. Product authority is `main`; durable Project Manager state authority is `manager-state`.
   - source: Owner-approved manager installation on 2026-10-01
   - authority: owner-directive

3. Current product authority is `main@a43d23653a056defffb987c342312b204d357012`.
   - source: live GitHub repository state
   - authority: verified-repository

4. Current installable development release is `dev-a43d236`. It contains a full fallback Setup, incremental update packages, and the first exact publish manifest.
   - full Setup SHA-256: `78b81c79f1cc0edd8442cacc041c03159119331ccd0ef8bf5aaf415f5520e7f3`
   - publish manifest SHA-256: `181b362d3f24d14863e72f018c00b9dfb36223ca911b348b7014d5e34d3cd380`
   - source: GitHub Release and successful main workflow
   - authority: verified-repository / verified-ci

5. Incremental update packages are now the preferred ordinary upgrade path. A delta ZIP contains only changed/added application files, removed-file metadata, a base SHA-256 manifest, and a rollback-capable updater.
   - source: `main@a43d23653a056defffb987c342312b204d357012`
   - authority: verified-repository / verified-ci / owner-directive

6. The updater validates the expected installed base before changing files, closes the application, backs up touched files, applies the delta, verifies target hashes, rolls back on failure, and restarts the application. It never modifies the WebView2 profile path.
   - source: updater implementation + CI syntax/smoke tests
   - authority: verified-repository / verified-ci

7. Starting with `dev-a43d236`, each development release publishes `ChatGptDesktopLocalBridge-PublishManifest.json` containing exact SHA-256 hashes for the actual publish used by that release. Future deltas prefer this manifest instead of reconstructing the old build.
   - source: release `dev-a43d236`
   - authority: verified-repository / verified-ci

8. Legacy releases without an exact publish manifest use a reconstruction fallback. This path is fail-safe: a delta refuses to apply when the installed baseline hashes do not match.
   - source: delta builder/updater implementation
   - authority: verified-repository

9. The Owner's currently installed baseline is `dev-1d00606`. A legacy delta from that version to `dev-9c8b8b7` is published at 135,943 bytes, followed by a delta from `dev-9c8b8b7` to manifest-backed `dev-a43d236` at 133,678 bytes.
   - source: current GitHub releases + Owner live status
   - authority: verified-repository / verified-runtime

10. Repository storage policy is enforced in CI: generated binaries/packages are ignored by Git; ordinary dev releases retain at most the two newest installable prereleases; stable releases are not touched.
    - source: current product source and successful cleanup workflows
    - authority: verified-repository / verified-ci / owner-directive

11. ChatGPT authentication continuity is based on `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`, outside the application install directory. Setup and delta update paths do not intentionally alter that profile.
    - source: product architecture
    - authority: verified-repository

12. BRIDGE-M1 live evidence remains: Diagnostics on the pre-fix installed baseline returned `Diagnostics failed: Local Bridge adapter is not injected.` The document-start adapter fix is present in all current post-fix releases, but still awaits Owner live validation.
    - source: Owner live report + current source
    - authority: verified-runtime / verified-repository
