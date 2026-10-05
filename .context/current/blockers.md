# Current blockers and open risks

Updated: 2026-10-05 20:02 MSK

No blocker remains for read-plane, Pause/Resume, Schedule mutation, existing-task arm/rearm, prompt mutation or Library file lifecycle.

Current proof gaps:
- first complete Scheduled runtime request-file -> result-file execution is not yet proven;
- the current E2E runner needs shorter independent phases instead of one long WebView diagnostic session;
- the temporary E2E probe worker is disabled and must stay disabled until its pre-test configuration is safely recovered or the probe is retired;
- explicit READY/ACK and correlation fencing remain unimplemented;
- dedicated new-worker creation remains unresolved;
- unattended-write recovery and endurance remain untested.

Safety rule: interrupted probes must be reconciled before any affected task is re-enabled.
