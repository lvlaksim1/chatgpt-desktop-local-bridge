# Current blockers and open risks

Updated: 2026-10-01 20:00 MSK

## Immediate BRIDGE-M1 gate
The adapter fix and compact update system are implemented and CI-verified, but Owner-side live validation remains required.

## Legacy delta caveat
`dev-1d00606` and `dev-9c8b8b7` predate exact release publish manifests. Their delta baselines use reconstruction fallback. The updater performs full baseline SHA verification and will refuse the update if reconstruction does not match the installed files; no partial update should occur.

Once the installation reaches `dev-a43d236`, later delta baselines use exact release manifests.

## Authentication continuity
No known blocker. Setup migration already preserved ChatGPT authentication. Delta updater does not touch the WebView2 profile.

## Reliability debt before mutating tools
RAM-only request deduplication remains insufficient for destructive/write/shell/process actions.

## Process-control debt
Windows Job Object emergency STOP is not yet implemented.
