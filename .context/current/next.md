# Next actions

Updated: 2026-10-02 17:35 MSK

1. Use Local Bridge + local `git`/`gh` as the default GitHub execution channel whenever the bridge is available.
2. Avoid one chat round trip per trivial CLI command; group a complete bounded work stage into one `process.run` call when safe.
3. Reconcile `m4-process-run-write-tools` and its write-tools ancestor with product authority `main` while preserving the exact `ea074e0` transport behavior.
4. Preserve the later M3 durable ledger/recovery work deliberately during reconciliation.
5. Reproduce the staged-but-not-auto-submitted result case and harden result delivery confirmation without abandoning the proven architecture.
6. Add Windows Job Object or equivalent robust bridge-owned process containment before broad shell/process expansion.
7. After reconciliation, rerun the unchanged `C:/Windows/win.ini` benchmark and smoke-test file mutation plus `git`/`gh` execution.
8. Keep release retention clean; avoid unnecessary large Actions artifacts and avoid creating new installable prereleases when existing proof builds suffice.
9. Persist future significant state changes to `manager-state`; prefer doing so through the newly proven Local Bridge CLI path rather than the ChatGPT GitHub connector.
