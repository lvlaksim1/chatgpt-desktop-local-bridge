# DEC-0004 — Repository and development-release storage retention

Date: 2026-10-01
Status: accepted
Authority: Owner directive + verified implementation evidence

## Decision

Keep the repository and GitHub storage compact by default.

1. Generated installers/packages/build outputs are not committed to Git.
2. Normal development prereleases publish only `ChatGptDesktopLocalBridge-Setup.exe`.
3. Portable ZIP is not a routine retained release asset.
4. Automatically retain at most the two newest installable `dev-*` prereleases as rollback buffer.
5. Automatically delete obsolete portable-only development releases and their tags.
6. Automatically remove redundant portable ZIP assets from retained development releases.
7. Stable/non-development releases are excluded from this cleanup.
8. GitHub Actions artifacts are not used for ordinary build/package storage.

## Verification

Implementation merged at `main@724a64b7f1ccc0ec92cd95fb511ecf1acb74ca95`.
The first main-branch cleanup workflow completed successfully.
After cleanup, Releases contained only `dev-1d00606`, with one Setup.exe asset.
