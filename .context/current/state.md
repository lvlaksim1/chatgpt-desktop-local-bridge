# Current state

Updated: 2026-10-05 20:02 MSK

- manager generation: 27
- product main: 6e2a0b54b727c5474bad40ac038f727a39cceb8d
- production Local Bridge: unchanged
- authenticated private read-plane: PASS
- Pause/Resume: PASS
- Task Schedule create/update/remove: PASS
- existing-task arm/rearm with restoration: PASS (run 37341819835)
- existing-task prompt mutation with restoration: PASS (run 37342848518)
- Library lifecycle including exact byte read-back and cleanup: PASS (run 37336624243)
- dedicated new-worker creation remains unresolved
- first full Scheduled+Library E2E attempt #240 / run 37343267811: FAIL because the long-lived diagnostic WebSocket closed before a terminal result was returned
- reconciliation #241 / run 37344708850: PASS
- reconciliation proved: one temporary worker found, request file present, result file absent, worker run had not advanced, worker disabled, request file cleaned
- ordinary desktop app restore #243 / run 37345374055: PASS
- temporary E2E worker remains disabled and must not be reused until its pre-test configuration is safely recovered or the probe task is retired
- runner branch: exp/runner-private-transport-control-plane
- draft PR #30
