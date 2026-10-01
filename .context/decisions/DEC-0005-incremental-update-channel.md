# DEC-0005 — Incremental update channel and exact publish manifests

Date: 2026-10-01
Status: accepted
Authority: Owner directive + verified implementation evidence

## Decision

Use compact delta update packages as the normal development-upgrade path.

Each delta:
- targets a specific prior dev release;
- contains only changed/added application files plus deletion metadata;
- carries baseline and target SHA-256 information;
- verifies the installed base before mutation;
- backs up touched files;
- rolls back on failure;
- restarts the application after success;
- does not modify the WebView2 profile.

The full Setup remains available for first installation, incompatible/missing delta bases, and recovery.

## Exact release authority

Beginning with `dev-a43d236`, every dev release publishes `ChatGptDesktopLocalBridge-PublishManifest.json`, containing the exact hashes of the publish that was packaged.

Future delta generation must prefer that manifest as the base authority. Reconstructing an old publish is only a legacy fallback for releases created before this decision.

## Verification

- delta-builder smoke test: PASS
- exact-manifest smoke path: PASS
- real delta generation: PASS
- installer build: PASS
- development release publication: PASS
- storage retention: PASS
