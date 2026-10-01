# Manager intentions and commitments

## Completed

### BRIDGE-M0 — MVP build and first development package
- status: completed
- product evidence: `main@977a504be19e2d21cb3c524275b003b9a6db7592`
- release evidence: `dev-977a504`
- verification: Windows CI restore/build/self-contained publish/ZIP/prerelease succeeded

### BRIDGE-M0A — Install/upgrade channel with persistent auth profile
- status: completed
- owner authorization: direct Owner directive on 2026-10-01
- product evidence: `main@1d006065462d442e429478158e655e3edc5c7938`
- release evidence: `dev-1d00606`
- verification: PR CI and main CI successfully compiled the Inno Setup installer
- continuity rule: program upgrades do not replace/delete `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

### BRIDGE-M0B — Repository/release storage hygiene
- status: completed
- owner authorization: direct Owner directive on 2026-10-01
- product evidence: `main@724a64b7f1ccc0ec92cd95fb511ecf1acb74ca95`
- CI evidence: main workflow completed successfully, including `Enforce development release retention`
- resulting release state: only `dev-1d00606` remains and it contains only `ChatGptDesktopLocalBridge-Setup.exe`
- durable policy: retain at most two installable dev prereleases; delete portable-only dev releases/tags and redundant ZIP assets; do not touch stable releases; generated installers/packages remain ignored by Git

## Active

### BRIDGE-M1 — Live end-to-end bridge proof
- status: accepted/active
- owner authorization: direct Owner development directive
- live evidence: Diagnostics on `dev-977a504` failed with `Local Bridge adapter is not injected`
- current diagnosis: probable early-document adapter bootstrap failure; patch not yet live-verified
- objective: prove `ChatGPT -> Web adapter -> C# bridge -> local tool -> RESULT -> ChatGPT` on the Owner's Windows machine
- minimum acceptance evidence:
  1. Diagnostics reports adapter/WebView/composer state;
  2. Initialize reaches `Bridge ready. Session ...`;
  3. `fs.read_text` reads a known local test file and the final answer returns through the same conversation.
- responsibility: `chatgpt-desktop-local-bridge-project-manager`

### BRIDGE-M2 — Web adapter reliability hardening
- status: accepted/active
- owner authorization: Owner approved the reviewed hardening roadmap on 2026-10-01
- objective: add generation detection, visible DOM selection, verified submission, robust fallback submission, and fail-closed DOM pause/error behavior
- completion rule: code merged to product authority only after Windows CI and a focused live acceptance check

### BRIDGE-M3 — Durable execution foundation
- status: accepted/active
- owner authorization: Owner approved the reviewed hardening roadmap on 2026-10-01
- objective: introduce explicit bridge states, capability registry, bounded large-result handling, durable request identity/replay protection, distinct result-delivery state, and recovery semantics
- completion rule: deterministic tests plus recovery/replay tests must demonstrate no unintended re-execution

### BRIDGE-M4 — Controlled mutating/process capabilities
- status: accepted/active
- owner authorization: Owner approved the roadmap direction; implementation is gated by BRIDGE-M3
- objective: add safe deterministic mutation primitives and later shell/process execution
- prerequisite: durable replay protection must exist before destructive/mutating actions; Windows Job Object emergency STOP must exist before shell/process expansion
