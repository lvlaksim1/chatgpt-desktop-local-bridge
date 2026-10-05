# Current blockers and open risks

Updated: 2026-10-05 23:02 MSK

No blocker remains for authenticated reads, Pause/Resume, schedule mutation, existing-task arm/rearm mutation, prompt mutation or Library lifecycle.

Current proof gap:
- a phased worker can be armed and enabled with successful read-back, but in the latest E2E probe its Scheduled run did not advance and no result file appeared;
- exact next-run scheduling/trigger semantics for the borrowed worker must be compared with known executing tasks;
- first complete request-file -> Scheduled runtime -> result-file cycle is therefore still unproven;
- READY/ACK and correlation fencing remain future work;
- unattended interruption/network-loss recovery and endurance remain untested.

Safety constraints:
- every explicit network/API/backend request must have at least 5000 ms separation;
- no parallel/burst requests;
- interrupted probes must be reconciled before an affected task is re-enabled.
