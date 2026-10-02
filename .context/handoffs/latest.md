# Latest handoff

Updated: 2026-10-02 17:35 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 15.
Product authority: `main`.
Manager-state authority: `manager-state`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.

## Critical transport baseline
The Owner manually proved the exact-morning `ea074e0` application still completes the full `fs.read_text(C:/Windows/win.ini)` Local Bridge round trip in the current environment. Later transport behavior must preserve this invariant.

## New M4 capability proof
An `ea074e0`-derived development lineage now has live-proven mutation and process execution.

Write tools:
- branch `m4-write-tools-ea074e0`
- prerelease `dev-ea074e0-write-tools`
- `fs.write_text`, `fs.append_text`, `fs.write_file`
- live append to `D:/test/file.txt`: PASS

Process tool:
- branch `m4-process-run-write-tools`
- prerelease `dev-process-run`
- `process.run` with structured args/cwd/timeout/output capture
- `git --version`: PASS
- `gh --version`: PASS
- `gh auth status`: PASS for `lvlaksim1`
- `gh repo view lvlaksim1/chatgpt-desktop-local-bridge`: PASS

Full installer:
- `ChatGptDesktopLocalBridge-process-run-Setup.exe`
- SHA-256 `ceec3c9c0204624979ee344b7a26a59821247618bc43645c9493f4dfbcf35d60`

## Owner directive
Future GitHub manipulation should normally be performed through Local Bridge using the user's local `git`, `gh`, and PowerShell environment. Do not default back to the ChatGPT GitHub connector when the bridge is available. Connector use is an explicit exception.

## Known weakness
The `gh --version` result was once staged successfully but not auto-submitted; the Owner manually sent it. Later process results auto-delivered. Treat this as an intermittent result transport issue.

## Next task
Reconcile the proven M4 development lineage with later M3/`main` functionality without losing the `ea074e0` transport invariant or M3 durability. Then harden result auto-submit and process containment.
