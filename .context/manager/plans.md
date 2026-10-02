# Manager plans

Manager generation: 15.
Product authority: `main`.
Current known authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.

## Closed milestones
- BRIDGE-M1: CLOSED.
- BRIDGE-M2: CLOSED.

## BRIDGE-M3
Durable execution/delivery is substantially implemented on `main`, but the product lineage must still be reconciled with the proven `ea074e0` transport behavior.

## BRIDGE-M4 proven slice

Filesystem mutation:
- branch `m4-write-tools-ea074e0`
- commits `c13781814ade651ee6b7d51f37a4b37ad997491b`, `826674c158df8ad868ec85823adbc2b38bb1653d`
- workflow commit `38c2aca554268a07343b8e1a6c805e787b3971f9`
- prerelease `dev-ea074e0-write-tools`
- live `fs.append_text(D:/test/file.txt)`: PASS

Process/CLI:
- branch `m4-process-run-write-tools`
- commits `a2c00c7619506c5aa0e98a523fc4b14ad255d141`, `ef2ac99a73cdc3c9a8fba8965d3a6ee9714e2753`
- workflow commit `cdb78c9d5f1a230d012f26fca1e391be5c5c23f9`
- prerelease `dev-process-run`
- local Git, GitHub CLI, GitHub auth, and remote repo query: PASS

Distribution:
- full setup SHA-256 `ceec3c9c0204624979ee344b7a26a59821247618bc43645c9493f4dfbcf35d60`
- incremental updater SHA-256 `03fde14068ca7159ed8be3c7f3b9d6b8d861f9cff58b5ae20bca82cf35d61fd6`

## Immediate plan
1. Treat Local Bridge + local CLI as the normal GitHub-control channel.
2. Prefer direct `git.exe`/`gh.exe`; batch dependent work into one bounded noninteractive process stage when useful.
3. Reconcile the proven write/process lineage with `main` without reintroducing the post-`ea074e0` transport regression or discarding M3 durability.
4. Reproduce and harden the staged-but-not-auto-sent result condition.
5. Add stronger bridge-owned process containment before broad shell/process expansion.
6. After reconciliation, rerun the unchanged `win.ini` benchmark plus write/process smoke tests.
7. Keep development-release retention clean and avoid unnecessary large Actions artifacts.

Interactive efficiency rule: local commands are fast; chat round trips dominate latency. Do not spend one bridge turn per trivial command when a safe bounded batch can complete the stage.
