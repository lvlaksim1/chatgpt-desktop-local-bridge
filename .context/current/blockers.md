# Current blockers and open risks

Updated: 2026-10-06 05:32 MSK

No blocker remains for authenticated reads, Pause/Resume, schedule mutation, existing-task arm/rearm mutation, prompt mutation, Library lifecycle, or UTC one-shot Scheduled runtime triggering.

Current proof gap:
- a fresh one-shot worker run advances, but the complete request-file -> Scheduled runtime -> result-file cycle is still unproven;
- #284 exposes a likely capability boundary: a Scheduled/runtime context can read Library inputs but may lack a direct JSON/in-memory -> new Library file creation primitive;
- #284 cannot yet be treated as causal proof for the latest one-shot run because the returned backing-run created_at predates that probe and the task had already been restored by Phase C;
- the next run must persist a backing-run identifier/timestamp and bounded body before cleanup;
- if direct Library result creation is genuinely unavailable, a different first-party return channel must be proven;
- READY/ACK and correlation fencing remain future work;
- unattended interruption/network-loss recovery and endurance remain untested.

Harness note:
- #284 workflow itself produced valid project evidence; its GitHub issue-completion step failed with HTTP 400, so Action/issue status must not be mistaken for experiment failure.

Safety constraints:
- every explicit network/API/backend request must have at least 5000 ms separation;
- no parallel/burst requests;
- interrupted probes must be reconciled before an affected task is re-enabled.
