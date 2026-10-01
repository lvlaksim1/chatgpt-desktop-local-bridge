# Manager plans

## Current planning state

Manager generation: 6.
Product authority: `main@a43d23653a056defffb987c342312b204d357012`.
Current manifest-backed release: `dev-a43d236`.
Owner installed baseline: `dev-1d00606`.
BRIDGE-M1: ACTIVE.

## Immediate live update path

1. Apply `ChatGptDesktopLocalBridge-Update-from-dev-1d00606.zip` from release `dev-9c8b8b7`.
2. Confirm updater succeeds and application restarts with ChatGPT session intact.
3. Apply `ChatGptDesktopLocalBridge-Update-from-dev-9c8b8b7.zip` from release `dev-a43d236`.
4. Confirm updater succeeds and ChatGPT session remains intact.
5. The installation is then on the first exact-manifest update baseline.
6. Press Diagnostics before Initialize Bridge.
7. If Diagnostics reports adapter v2, proceed to Initialize Bridge and require nonce-bound READY.
8. Prove one known-file `fs.read_text` round trip.

## Future update policy

- Prefer a matching `ChatGptDesktopLocalBridge-Update-from-dev-*.zip` over the full Setup.
- Extract the ZIP and run `Apply-Update.cmd`.
- The updater must refuse mismatched bases rather than partially updating.
- Each release publishes an exact publish manifest; later deltas use it as authority.
- Keep full Setup in the current release for fresh installation and recovery.
- Retain compact development release storage according to DEC-0004.

## Follow-on engineering

After BRIDGE-M1 closes:
1. BRIDGE-M2 adapter hardening.
2. BRIDGE-M3 native reliability and durable execution.
3. deterministic mutation primitives.
4. Windows Job Object Emergency STOP.
5. shell/process, Git, Excel, browser/UI capability families.
