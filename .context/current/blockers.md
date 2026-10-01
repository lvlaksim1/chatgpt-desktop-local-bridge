# Current blockers and open risks

Updated: 2026-10-01 19:31 MSK

## Immediate BRIDGE-M1 gate
The adapter-bootstrap fix is implemented, CI-verified, packaged, and published in `dev-450b884`, but not yet live-verified in a signed-in ChatGPT WebView2 session.

If Diagnostics on `dev-450b884` reports adapter v2, the earlier early-document hypothesis is confirmed and this blocker advances to handshake testing.

If it still reports adapter not injected, the root cause remains unresolved and the next investigation must focus on script registration/execution evidence.

## Authentication continuity
The installed baseline already inherited the existing ChatGPT session successfully. The next upgrade from `dev-1d00606` to `dev-450b884` is the first direct in-place-upgrade persistence test.

## Repository storage
No active storage blocker. Retention is automatic and currently holds only the two newest installable dev prereleases.

## Reliability debt before mutating tools
Current request deduplication is process-memory-only. It is adequate for the read-only MVP test but not sufficient for destructive, write, shell, or process actions across restart/crash boundaries.

## Process-control debt
There is not yet a Windows Job Object containment/emergency-STOP layer. Shell/process capabilities must not be treated as production-ready before that foundation exists.
