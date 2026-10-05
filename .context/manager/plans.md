# Manager plans

Manager generation: 25.
Updated: 2026-10-05 17:52 MSK

## Immediate runner-driven plan
1. Keep PR #30 as the autonomous Windows test harness.
2. Add bounded network/DOM discovery for Task Schedule without requiring Owner clicks.
3. Identify schedule write method/path/body and its authoritative read-back, using a disposable/safe task and restoring its original schedule.
4. Discover one-shot arm/rearm semantics with the same restore-first discipline.
5. Add runner probes for Library/file lifecycle, using disposable uniquely named transport files and cleanup.
6. After contracts are proven, implement the minimal ScheduledFileTransport E2E.
7. Run restart, duplicate, stale-ACK, relogin/navigation, network-loss, large-payload and 100+ sequential round-trip tests.

Other tracks remain independent: PR #22 runtime foundation, UI candidate 4c92f81, PR #23 ChatGPT-plan transport.
