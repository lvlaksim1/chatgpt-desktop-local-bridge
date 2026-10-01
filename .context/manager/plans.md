# Manager plans

Manager generation: 8.
Product authority: `main@4ed78c23fceddf628996be5a87a9847889c950e7`.
Current release: `dev-4ed78c2`.
Owner installed baseline: `dev-1d00606` unless Owner reports successful migration.

## Immediate BRIDGE-M1 path

1. Do not retry any earlier ZIP updater or earlier broken single-EXE updater.
2. Run `dev-4ed78c2 / ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`.
3. The updater must validate legacy base `0.1.24.0` + stable fingerprints, use .NET SHA-256, back up touched files, apply the current target, verify hashes, create `release-info.json`, register the uninstall wrapper, and restart the application.
4. Confirm ChatGPT authentication remains intact.
5. Press Diagnostics before Initialize Bridge.
6. If adapter v2 is reported, Initialize Bridge and require READY.
7. Prove `fs.read_text` end-to-end.

## Update policy

- Give Owner one matching `Update-from-*.exe`, not ZIP archives.
- Full Setup remains first-install/fallback only.
- Future deltas use exact release-info + PublishManifest authority.
- Runtime updater must remain compatible with Windows PowerShell used by Inno; do not depend on optional cmdlets when a direct .NET API is available.
- Every delta-capable release must preserve/update normal uninstall behavior through the shipped uninstall wrapper.
- Keep at most two installable dev releases and no ordinary Actions artifacts.

## Follow-on engineering

After BRIDGE-M1 closes:
1. BRIDGE-M2 adapter hardening.
2. BRIDGE-M3 explicit state machine, capability registry, bounded results, durable request ledger and delivery recovery.
3. deterministic mutation primitives.
4. Windows Job Object Emergency STOP.
5. shell/process, Git, Excel, browser/UI capability families.
