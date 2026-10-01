# Next actions

Updated: 2026-10-01 19:02 MSK

1. Install/retain `dev-1d00606 / ChatGptDesktopLocalBridge-Setup.exe` as the persistent application baseline.
2. Establish/confirm ChatGPT sign-in in the application's own WebView2 profile if needed.
3. Resume the focused early-DOM adapter bootstrap fix.
4. Build the next installer with the same stable AppId; normal release automation will publish installer only and enforce retention.
5. Install the new version over the current one and verify ChatGPT sign-in remains intact.
6. Run Diagnostics and verify adapter injection.
7. Prove nonce-bound `Bridge ready`.
8. Prove one known-file `fs.read_text` end-to-end round trip.
9. Persist BRIDGE-M1 evidence.
10. Continue BRIDGE-M2 adapter hardening.
11. Implement BRIDGE-M3 state machine, capability registry, bounded results, durable request ledger, and delivery-state recovery.
12. Add deterministic mutation primitives, then Windows Job Object Emergency STOP before shell/process expansion.
