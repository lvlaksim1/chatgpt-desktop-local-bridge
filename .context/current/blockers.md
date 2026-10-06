# Current blockers and open risks

Updated: 2026-10-06 07:14 MSK

No blocker remains for authenticated reads, Pause/Resume, schedule mutation, existing-task arm/rearm mutation, prompt mutation, Desktop-side Library lifecycle, UTC one-shot Scheduled runtime triggering, or causal identification of the resulting backing run.

Current proof gap:
- the tested Library-file request path fails inside Scheduled runtime: the causally matched worker reports that the exact freshly created Library request file was not found;
- therefore the first complete Desktop -> Scheduled runtime -> Desktop transport cycle is still unproven;
- worker-side Library discovery/read visibility must not be assumed from Desktop-side Library API success;
- prompt-as-request + latest_backing_run-as-result is not yet tested as the replacement critical path;
- READY/ACK, generation/seq fencing, duplicate suppression, interruption recovery and endurance remain future work.

Safety/interpretation:
- Action failures for evidence readers are expected when project status is `evidence`/exit 20; do not classify them as experiment failure.
- #292 issue-completion HTTP 400 is a gateway callback/reporting failure after valid local evidence was already produced, not a backend experiment failure.
- every explicit network/API/backend request must have at least 5000 ms separation;
- no parallel/burst requests;
- interrupted probes must be reconciled before an affected task is re-enabled.
