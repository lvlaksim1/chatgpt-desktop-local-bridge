# Manager intentions and commitments

## Completed

### BRIDGE-M0 — MVP build and first development package
- status: completed

### BRIDGE-M0A — Install/upgrade channel with persistent auth profile
- status: completed
- evidence: `dev-1d00606`
- rule: WebView2 profile remains outside install directory

### BRIDGE-M0B — Repository/release storage hygiene
- status: completed
- evidence: `main@724a64b7f1ccc0ec92cd95fb511ecf1acb74ca95`

### BRIDGE-M0C — Incremental update channel
- status: completed
- owner authorization: direct Owner request on 2026-10-01
- product evidence: `main@a43d23653a056defffb987c342312b204d357012`
- CI evidence: PowerShell syntax, delta smoke generation, installer build, real delta generation, release publication, and retention cleanup all passed
- release evidence: `dev-a43d236`
- policy: delta update is preferred for ordinary upgrades; full Setup remains first-install/fallback
- deterministic baseline: exact publish manifests are published beginning with `dev-a43d236`

## Active

### BRIDGE-M1 — Live end-to-end bridge proof
- status: accepted/active
- live evidence: pre-fix Diagnostics failed with `Local Bridge adapter is not injected`
- current gate: move Owner installation from `dev-1d00606` through compact delta updates to `dev-a43d236`, confirm authentication survives, then rerun Diagnostics
- minimum acceptance evidence:
  1. Diagnostics reports adapter v2/WebView/composer state;
  2. Initialize reaches `Bridge ready. Session ...`;
  3. `fs.read_text` reads a known local test file and final answer returns through the same conversation.

### BRIDGE-M2 — Web adapter reliability hardening
- status: accepted/active
- objective: generation detection, visible DOM selection, verified submission, robust fallback submission, fail-closed DOM behavior

### BRIDGE-M3 — Durable execution foundation
- status: accepted/active
- objective: explicit bridge states, capability registry, bounded results, durable exactly-once execution, separate delivery recovery

### BRIDGE-M4 — Controlled mutating/process capabilities
- status: accepted/active
- prerequisite: durable replay protection before destructive actions; Windows Job Object Emergency STOP before shell/process expansion
