# Next actions

Updated: 2026-10-05 20:02 MSK

1. Keep the reconciled E2E probe worker disabled.
2. Recover its pre-test configuration safely if available; otherwise retire or quarantine it rather than guessing.
3. Refactor E2E into short crash-safe phases with durable recovery metadata before mutation.
4. Re-run request file -> arm -> Scheduled runtime -> result file using fresh observation sessions.
5. On PASS, add READY/ACK and correlation fencing.
6. Start durability and endurance testing.
