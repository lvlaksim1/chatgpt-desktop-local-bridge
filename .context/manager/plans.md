# Manager plans

Manager generation: 17.
Product authority: `main`.
Current known authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI runtime baseline: `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053`.\nCurrent validation candidate: `ui-shell-4c92f81` / `4c92f81d46b77f964b8e99fe25439058b9b835a1` on `dev/ui-shell-v5`.

## Closed milestones
- BRIDGE-M1: CLOSED.
- BRIDGE-M2: CLOSED.

## UI-SHELL-R1 recovery plan

The requested implementation stage 1–7 is code-complete and CI-complete on validation candidate `4c92f81`.

Implemented slices:
1. `f30424d` — ordinary-WebView paint stabilization, page-owned loading/switch shield, native background matching, warm parent-only tab switching, background preload preservation.
2. `0ff4286b` — removal of `NewWindowRequested` interception, adapter-v7 DOM context target publication, safe custom app-tab action with no `ContextMenuTarget.LinkUri`.
3. `ee6ce6e` — broader unified ChatGPT theme coverage plus explicit default-theme reset.
4. `4c92f81` — delta-only top updater, full Setup under Settings → Updates, prerelease packaging.

Validation gate:
- CI run `37092162098`: PASS.
- Prerelease `ui-shell-4c92f81`: published.
- Owner-side signed-in Windows validation: PENDING.
- Accepted runtime baseline remains `af6ac653` until that validation passes.

Owner validation order:
1. startup and first navigation;
2. loading/black-area behavior;
3. switching already-loaded tabs and background preload;
4. ordinary download-link behavior;
5. right-click custom “Открыть в новой вкладке” without crash;
6. Local Bridge auto-restore;
7. unified theme coverage and “Сбросить тему”;
8. updater placement/behavior.

If any regression appears, map it to the isolated commit slice and repair/revert that slice first. Do not stack another broad WebView rewrite on an unverified candidate.

After Owner PASS, promote the validated commit as next UI baseline and proceed to Diagnostics, transport hardening, fine-grained ASK permissions, local-tool expansion, and production hardening.

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

## Cross-track plan
1. Stabilize the UI recovery lineage from 0.2.8 without disturbing the proven bridge behavior.
2. Treat Local Bridge + local CLI as the normal GitHub-control channel when available.
3. Reconcile the proven write/process lineage with `main` without reintroducing the post-`ea074e0` transport regression or discarding M3 durability.
4. Reproduce and harden the staged-but-not-auto-sent result condition.
5. Add stronger bridge-owned process containment before broad shell/process expansion.
6. After reconciliation, rerun the unchanged `win.ini` benchmark plus write/process smoke tests.
7. Keep development-release retention clean and avoid unnecessary large Actions artifacts.
