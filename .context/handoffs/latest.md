# Latest handoff

Updated: 2026-10-01 19:31 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 5.
Product authority: `main@450b884423696b70905db394c68ddc45b2ba03ec`.

## Current release
`dev-450b884` contains only `ChatGptDesktopLocalBridge-Setup.exe`.
SHA-256: `0757703080c8d334602b6d9882da9f565cd6d5361a88b05d17404c3bc0cb4cb0`.

## BRIDGE-M1
The live `adapter is not injected` failure was reproduced on the installed baseline. A focused document-start patch is now published:
- bridge registration occurs before observer setup;
- observer targets `document`;
- health reports adapter v2;
- JS syntax is checked in CI.

All CI/package/release steps passed. Live validation remains open.

## Required continuation
Install `dev-450b884` over the current installation. Confirm the ChatGPT session remains authenticated. Press Diagnostics before Initialize Bridge and report the exact result.

Do not claim BRIDGE-M1 success until READY and a local `fs.read_text` round trip are both proven.
