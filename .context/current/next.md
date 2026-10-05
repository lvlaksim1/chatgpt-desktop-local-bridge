# Next actions

Updated: 2026-10-05 15:42 MSK

1. Use PR #27 / `private-transport-v3-70d3b29` as the current private-transport live test candidate; do not advance the no-op v4 branch.
2. On the Owner signed-in runtime, run the narrow Private Read Proof and capture current Scheduled Tasks + Library backend behavior.
3. Capture exact current task mutation requests for pause/resume/schedule/arm and identify authoritative read-back routes.
4. Capture/verify the file/Library transport lifecycle needed for disposable `request.json` and `result.json` objects.
5. For any mutating timeout or connection loss, enter `UNKNOWN_OUTCOME` and reconcile by read-back; never blind-retry.
6. Implement only protocol-specific narrow capabilities after live capture. Do not expose arbitrary internal fetch.
7. Execute the first no-composer/no-DOM-input E2E: Desktop writes request file, sets READY, arms worker, Scheduled runtime writes result file then ACK, Desktop validates fencing and reads result.
8. If E2E passes, run restart/duplicate/stale-ACK/navigation/relogin/network-loss/large-payload and 100+ sequential round-trip tests before promotion.
9. Keep production Local Bridge/DOM transport as fallback throughout R&D.
10. Independently complete PR #22 Owner runtime validation and UI-SHELL-R1 Owner validation; do not combine those promotions with private transport.
11. Separately live-test official ChatGPT-plan transport PR #23 when desired.
