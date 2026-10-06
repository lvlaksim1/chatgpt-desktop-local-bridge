# Current blockers and open risks

Updated: 2026-10-06 04:30 MSK

No blocker remains for authenticated reads, Pause/Resume, schedule mutation, existing-task arm/rearm mutation, prompt mutation, Library lifecycle, or UTC one-shot Scheduled runtime triggering.

Current proof gap:
- the worker was armed with an authoritative future next_run and subsequently DID execute (`run_advanced=true`, `last_run_present=true`, latest backing run HTTP 200);
- despite the successful Scheduled run, no expected result Library file appeared;
- the worker's latest backing run must be inspected to identify whether the failure is prompt execution, runtime capability, Library access, result-file creation, or another explicit run outcome;
- first complete request-file -> Scheduled runtime -> result-file cycle is therefore still unproven;
- READY/ACK and correlation fencing remain future work;
- unattended interruption/network-loss recovery and endurance remain untested.

Safety constraints:
- every explicit network/API/backend request must have at least 5000 ms separation;
- no parallel/burst requests;
- interrupted probes must be reconciled before an affected task is re-enabled.
