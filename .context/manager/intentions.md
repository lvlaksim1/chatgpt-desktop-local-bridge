# Manager intentions and commitments

## Completed

### BRIDGE-M0A — Install/upgrade channel
- completed

### BRIDGE-M0B — Repository/release storage hygiene
- completed

### BRIDGE-M0C — Incremental update channel
- completed

### BRIDGE-M0D — Single-file incremental updater
- status: completed
- product evidence: `main@4ed78c23fceddf628996be5a87a9847889c950e7`
- release evidence: `dev-4ed78c2`
- root-cause remediation: replaced `Get-FileHash` with direct .NET SHA-256 hashing for Windows PowerShell compatibility
- verification: real legacy install -> Update.exe -> release marker E2E PASS

### BRIDGE-M0E — Delta-safe uninstall behavior
- status: completed
- product evidence: `main@4ed78c23fceddf628996be5a87a9847889c950e7`
- behavior: normal uninstall asks whether to delete settings/working data; No preserves them; Yes deletes them after program uninstall; quiet uninstall preserves them
- verification: legacy delta installed the wrapper; quiet uninstall removed program files and preserved a sentinel user-data file

## Active

### BRIDGE-M1 — Live end-to-end bridge proof
- current gate: Owner applies `dev-4ed78c2 / ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`
- then confirm application restart and ChatGPT authentication continuity
- then Diagnostics must report adapter v2
- then Initialize must reach nonce-bound READY
- then prove one local `fs.read_text` round trip

### BRIDGE-M2 — Web adapter reliability hardening
- accepted/active

### BRIDGE-M3 — Durable execution foundation
- accepted/active

### BRIDGE-M4 — Controlled mutating/process capabilities
- accepted/active
