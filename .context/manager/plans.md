# Manager plans

Manager generation: 9.
Product authority: `main`.
Current verified release: `dev-ea074e0@ea074e06bd4e959106f49f57cad1ac731597dac3`.
Owner installed release: `dev-ea074e0`.

## BRIDGE-M1 closure evidence

1. `Initialize Bridge -> READY`: PASS, pc-runner-gateway #160.
2. `READY -> fs.read_text(C:/Windows/win.ini) -> successful local execution/audit`: PASS, #164.
3. Product bootstrap corrected to require forward-slash Windows paths in bridge JSON.
4. Updated Owner PC to `dev-ea074e0`.
5. Final round-trip regression on `dev-ea074e0`: PASS, #166.
6. BRIDGE-M1 is CLOSED. Do not repeat M1 probes unless a later product change regresses this boundary.

## Immediate BRIDGE-M2 path

1. Harden adapter protocol diagnostics using evidence from the failed M1 probes.
2. Keep strict parsing: only an exact `LOCAL_BRIDGE_REQUEST_V1` envelope is executable.
3. When an assistant message contains bridge request markers but cannot be parsed, record a payload-free diagnostic reason such as invalid JSON / missing id / missing session / missing tool.
4. Surface last protocol event/failure and pending/processed counts through `health()` so Diagnostics immediately explains failures instead of forcing long audit waits.
5. Keep service-message hiding, current + legacy DOM selectors, 700 ms streaming stability gate, draft preservation, and no blind retry.
6. Add a bounded deterministic check for parser diagnostics and one short live regression only if product behavior changes.

## Follow-on engineering

After M2:
1. BRIDGE-M3 explicit state machine and capability registry.
2. Bound result size and establish durable request ledger + result-delivery recovery.
3. Deterministic filesystem mutation primitives.
4. Windows Job Object Emergency STOP.
5. Shell/process, Git, Excel, browser/UI capability families.

## Release/update policy

- Give Owner one matching `Update-from-*.exe`, not ZIP archives.
- Full Setup is first-install/fallback only.
- Keep at most two installable dev releases and avoid ordinary Actions artifacts.
- Do not create a new product release for test-script-only changes.
