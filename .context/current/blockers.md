# Current blockers and open risks

Updated: 2026-10-01 20:22 MSK

## BRIDGE-M1
Owner-side application of the new single-file legacy updater and subsequent Diagnostics are still required.

## Legacy migration
The old ZIP delta is invalid for the actually installed legacy build because reconstructed DLL bytes differ. It must not be retried. The replacement EXE uses a dedicated legacy validation mode and is the only intended migration path from `dev-1d00606`.

## Future updates
No known packaging blocker. Manifest-backed releases now have exact release markers and publish manifests.

## Reliability debt
Durable request ledger and Windows Job Object STOP remain future BRIDGE-M3/BRIDGE-M4 work.
