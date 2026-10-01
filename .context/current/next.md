# Next actions

Updated: 2026-10-01 18:50 MSK

1. Install `dev-1d00606 / ChatGptDesktopLocalBridge-Setup.exe` as the persistent application baseline.
2. Establish/confirm ChatGPT sign-in in the application's own WebView2 profile if needed.
3. Resume the focused early-DOM adapter bootstrap fix.
4. Build the next installer with the same stable AppId and install it over the current version.
5. Verify that ChatGPT sign-in remains intact across that upgrade.
6. Run Diagnostics and verify adapter injection.
7. Prove nonce-bound `Bridge ready`.
8. Prove one known-file `fs.read_text` end-to-end round trip.
9. Persist BRIDGE-M1 evidence.
10. Continue BRIDGE-M2 adapter hardening.
11. Implement BRIDGE-M3 state machine, capability registry, bounded results, durable request ledger, and delivery-state recovery.
12. Add deterministic mutation primitives, then Windows Job Object Emergency STOP before shell/process expansion.
