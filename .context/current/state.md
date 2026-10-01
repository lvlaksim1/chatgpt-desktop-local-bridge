# Current state

Updated: 2026-10-01 19:31 MSK

## Governance
- manager: `chatgpt-desktop-local-bridge-project-manager`
- manager generation: 5
- manager-state authority: `manager-state`
- product authority: `main@450b884423696b70905db394c68ddc45b2ba03ec`
- execution status: ACTIVE / BRIDGE-M1 live validation

## Current package
- preferred package: `dev-450b884 / ChatGptDesktopLocalBridge-Setup.exe`
- installer SHA-256: `0757703080c8d334602b6d9882da9f565cd6d5361a88b05d17404c3bc0cb4cb0`
- prior installed baseline: `dev-1d00606`
- stable AppId enables in-place upgrade
- persistent WebView2 UDF remains `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

## Adapter patch
Live failure before patch:
`Diagnostics failed: Local Bridge adapter is not injected.`

Patch in current main/release:
- register `window.__localBridge` before MutationObserver setup;
- observe `document` rather than potentially-null `document.documentElement`;
- adapter health version incremented to 2;
- CI validates adapter syntax with `node --check`.

All CI/package/release steps passed. Live confirmation is still required.

## Repository storage hygiene
- dev releases publish installer only
- automatic retention keeps at most two installable dev prereleases
- current releases: `dev-450b884` and rollback `dev-1d00606`
- no GitHub Actions artifact upload step is used

## Next live gate
Upgrade to `dev-450b884`, confirm ChatGPT remains signed in, then press Diagnostics before Initialize Bridge.
