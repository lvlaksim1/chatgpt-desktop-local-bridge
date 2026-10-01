# Manager intentions and commitments

## Completed

### BRIDGE-M0A — Install/upgrade channel
- completed

### BRIDGE-M0B — Storage hygiene
- completed

### BRIDGE-M0C — Incremental update channel
- completed

### BRIDGE-M0D — Single-file incremental update installers
- status: completed
- product evidence: `main@f7688fbca03286d756d5f262808c8b40ec4f3952`
- release evidence: `dev-f7688fb`
- current Owner migration asset: `ChatGptDesktopLocalBridge-Update-from-dev-1d00606.exe`
- verification: PR smoke EXE PASS; main real delta generation PASS; release publication PASS; retention cleanup PASS
- legacy rule: `dev-1d00606` is validated by Inno DisplayVersion + stable fingerprints, not rebuilt DLL identity
- normal future rule: release marker + exact publish manifest

## Active

### BRIDGE-M1 — Live end-to-end bridge proof
- current gate: Owner applies direct single EXE migration from `dev-1d00606` to `dev-f7688fb`
- then confirm ChatGPT session survives
- then Diagnostics must report injected adapter v2
- then Initialize must reach nonce-bound READY
- then prove one local `fs.read_text` round trip

### BRIDGE-M2 — Web adapter reliability hardening
- accepted/active

### BRIDGE-M3 — Durable execution foundation
- accepted/active

### BRIDGE-M4 — Controlled mutating/process capabilities
- accepted/active
