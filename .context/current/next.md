# Next actions

Updated: 2026-10-05 20:13 MSK

1. Keep the affected E2E worker disabled.
2. Recover its pre-test configuration safely if possible; otherwise retire/quarantine it.
3. Split E2E into bounded Phase A / B / C runner jobs with durable recovery metadata.
4. Retry request file -> arm -> Scheduled runtime -> result file using fresh sessions for observation and cleanup.
5. If PASS, add READY/ACK and correlation fencing.
6. Then run interruption/restart/duplicate/stale-ACK/relogin/navigation/network-loss/orphan-cleanup tests.
7. Run 100+ sequential round trips and large-payload endurance.
