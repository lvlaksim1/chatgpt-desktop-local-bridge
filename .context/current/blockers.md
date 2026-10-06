# Current blockers and open risks

Updated: 2026-10-06 07:35 MSK

The first bounded Desktop -> Scheduled runtime -> Desktop round trip is now proven through prompt input and latest_backing_run output.

Remaining proof gaps:
- current harness still performs incidental Library operations even though they are not part of the successful transport path;
- generation/seq fencing is not implemented;
- stale prior latest_backing_run rejection is not yet proven;
- duplicate execution/result handling is not yet proven;
- payload size/encoding limits are not characterized;
- interruption/relogin/navigation/network-loss recovery and endurance remain untested;
- production integration into Local Bridge is not approved.

Known failed primitive:
- a fresh Library request file that Desktop could create and read was not discoverable by the causally matched Scheduled worker.

Safety/interpretation:
- evidence-reader Action failures caused by deliberate exit 20 are not experiment failures;
- every explicit network/API/backend request must be separated by at least 5000 ms;
- no parallel/burst requests;
- interrupted probes must be reconciled before reuse.
