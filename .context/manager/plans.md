# Manager plans

## Current planning state

Manager generation: 5.
Product authority: `main@450b884423696b70905db394c68ddc45b2ba03ec`.
Current installable release: `dev-450b884`.
BRIDGE-M1: ACTIVE / adapter-bootstrap patch published, awaiting live upgrade validation.

## Immediate continuation — BRIDGE-M1

1. Install `dev-450b884 / ChatGptDesktopLocalBridge-Setup.exe` over the existing installed `dev-1d00606`.
2. Verify the ChatGPT session remains authenticated after upgrade.
3. Press Diagnostics before Initialize Bridge.
4. If Diagnostics reports adapter v2, classify the document-start patch as live-confirmed.
5. If Diagnostics still reports adapter not injected, collect the exact live status and inspect injection-registration evidence rather than broadening selectors.
6. If diagnostics passes, initialize the bridge and require nonce-bound READY.
7. Run a known-file `fs.read_text` round trip and verify the final model response.
8. Persist exact live evidence.

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

## Packaging, storage, and authentication continuity

- Preferred distribution: `ChatGptDesktopLocalBridge-Setup.exe`.
- Newer installers upgrade the same per-user application identity.
- Program files live under `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`.
- WebView2 profile remains under `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2` and is not part of normal application upgrade.
- Normal dev releases publish installer only; retain at most two newest installable `dev-*` prereleases.
- Stable releases are excluded from cleanup.
- Automatic background update discovery/download is not yet implemented; current guarantee is in-place upgrade when a newer Setup is run.
- Stable/production release remains Owner-gated.
