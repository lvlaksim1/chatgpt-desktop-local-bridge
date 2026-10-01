# Current blockers and open risks

Updated: 2026-10-02 01:46 MSK

## BRIDGE-M1
Only Owner-side live application of the latest E2E-validated updater and subsequent ChatGPT bridge validation remain.

## Obsolete update packages
Do not use prior ZIP deltas or earlier single-EXE updater builds. The current supported legacy migration is only the `dev-4ed78c2` update from `dev-1d00606`.

## Uninstall interaction
Quiet uninstall preservation has automated E2E evidence. The interactive Yes/No UI path is implemented in the same wrapper but requires normal user interaction on Windows; Yes deletes user data, No preserves it.

## Reliability debt
Durable request ledger and Windows Job Object STOP remain future BRIDGE-M3/BRIDGE-M4 work.
