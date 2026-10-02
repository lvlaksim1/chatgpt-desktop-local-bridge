# Manager plans

Manager generation: 10.
Product authority: `main`.
Current product head: `64152b68205a59e7df59d842c2acf972f717de33`.
Current verified release and Owner-installed release: `dev-aea8ad2@aea8ad2971dd7e138434b60d5dfd90c63a0f4a34`.

## Closed milestones

1. BRIDGE-M1: live READY and `fs.read_text` round trip are proven; do not rerun unless a later product change touches that boundary.
2. BRIDGE-M2: strict parser diagnostics, current/legacy DOM compatibility, streaming stability, draft protection, and bridge-owned stale-draft recovery are closed by deterministic checks plus live gateway #168.

## BRIDGE-M3 foundation now merged

1. Replace RAM-only request-id dedupe with an on-disk request ledger.
2. Persist `reserved`, `executing`, and `completed` execution states.
3. Track result delivery independently as `notReady`, `pending`, and `delivered`.
4. Fail closed on conflicting reuse of the same session/request id with different tool/args.
5. Persist only request fingerprint/state metadata; do not copy request arguments or local result contents into the ledger.
6. Mark execution completed before attempting ChatGPT result delivery, so delivery failure cannot cause blind local re-execution.
7. Deterministic restart/dedupe/conflict regression: PASS.
8. Full PR CI and post-merge main CI: PASS.

## Immediate M3 path

1. Define bounded durable storage for a completed result that is still `pending` delivery.
2. Define recovery binding so an old result is never injected into the wrong ChatGPT conversation/session.
3. Implement recovery of `completed/pending` by replaying the stored result, never by rerunning the local tool.
4. Add a capability registry so tool metadata, permission capability and bootstrap exposure have one authority.
5. Enforce a transport-level bound for serialized result payloads.
6. After this coherent M3 slice is complete, create one dev release, update the Owner PC once, and run one bounded live integration regression.

## Follow-on engineering

After M3:
1. Deterministic filesystem mutation primitives.
2. Windows Job Object Emergency STOP.
3. Shell/process, Git, Excel, browser/UI capability families.

## Release/update policy

- Give Owner one matching `Update-from-*.exe`, not ZIP archives.
- Full Setup is first-install/fallback only.
- Keep at most two installable dev releases and avoid ordinary Actions artifacts.
- Do not create a new product release for test-script-only or every internal M3 sub-step.
