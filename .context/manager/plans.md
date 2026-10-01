# Manager plans

## Current planning state

Manager generation: 2.
Product authority: `main@761f8369c0fa523834ba8c8baf819571684f5e98`.
Product-code/build baseline: `977a504be19e2d21cb3c524275b003b9a6db7592`.
Current live gate: Owner-side test of `dev-977a504`.

## Phase 1 — close BRIDGE-M1

1. Consume the Owner's Diagnostics output from the installed build.
2. If diagnostics fails, classify the failure as WebView injection, composer selector, send selector, or navigation/auth origin and patch only the evidenced layer.
3. If diagnostics passes, initialize the bridge and require nonce-bound READY.
4. Run a known-file `fs.read_text` round trip and verify the final model response.
5. Persist exact live evidence and any DOM compatibility findings.

## Phase 2 — BRIDGE-M2 adapter hardening

1. Add explicit `isGenerating()` detection using current ChatGPT stop controls.
2. Select only visible composer/send controls and prefer the composer-local send control.
3. Preserve any non-empty user draft; bridge-generated result delivery must not overwrite a draft.
4. Submit using bounded fallbacks: click -> form `requestSubmit` -> synthetic Enter.
5. Verify that submission actually initiated/cleared the staged bridge message.
6. On structural DOM failure, enter fail-closed `PAUSED / DOM ERROR` until explicit recovery.
7. Add deterministic adapter tests where practical.

## Phase 3 — BRIDGE-M3 native reliability

1. Introduce an explicit state machine: DISCONNECTED, INITIALIZING, READY, RUNNING, PAUSED, ERROR.
2. Replace the growing tool switch with a capability registry carrying schema, permission key, timeout policy, and handler.
3. Add bounded-result storage: inline preview plus local full result, SHA-256, byte count, and path.
4. Replace RAM-only request dedupe with a durable append-only execution ledger:
   - same ID + same request hash -> duplicate/no replay;
   - same ID + different hash -> conflict;
   - interrupted nonterminal operations -> INTERRUPTED, never blind replay.
5. Separate execution completion from delivery acknowledgement/retry.
6. Add recovery, duplicate, malformed-state, and crash-window tests.

## Phase 4 — BRIDGE-M4 capability expansion

1. Add `fs.stat`.
2. Add deterministic `fs.patch` before generic overwrite-heavy workflows.
3. Add write/mkdir/copy/move/delete according to external permissions policy.
4. Before shell/process tools, implement Windows Job Object containment and Emergency STOP.
5. Then add process/shell, Git, Excel, browser/UI families incrementally with focused tests.

## Packaging

Continue self-contained `win-x64` development prereleases when a live Owner test is needed. Do not use GitHub Actions artifacts merely as package storage. Stable/production release remains Owner-gated.
