# Current state

Updated: 2026-10-03 06:10 MSK

- manager generation: 17
- product authority: `main`
- current verified authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- manager-state authority: `manager-state`
- canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`
- BRIDGE-M1: CLOSED
- BRIDGE-M2: CLOSED
- BRIDGE-M3: ACTIVE; durable foundation substantially implemented, reconciliation with proven transport baseline still pending
- BRIDGE-M4: ACTIVE; first mutation/process slice live-proven on an `ea074e0`-derived development lineage
- UI-SHELL-R1: ACTIVE; implementation stage 1–7 is built/published and awaiting Owner runtime validation
- accepted UI runtime baseline remains `0.2.8.0` / `af6ac65306d5e91b84c48bb44fb7bc37da930053`
- validation candidate head: `4c92f81d46b77f964b8e99fe25439058b9b835a1` on `dev/ui-shell-v5`
- isolated implementation commits: `f30424d` → `0ff4286b` → `ee6ce6e` → `4c92f81`
- CI run `37092162098`: PASS
- prerelease: `ui-shell-4c92f81`, workflow version `0.2.15.0`
- delta from accepted `ui-shell-af6ac65`: SHA-256 `a7dafb406b6af3bc45c04f5ff889518fd52b97ba8bb229ae6f6a3f96cffbb618`, 2,264,856 bytes
- full Setup: SHA-256 `5a01b0a0609d91ef44e8356ab982f1dda3835201d18b8fc6b37252a45fceb59f`, 51,494,899 bytes
- candidate keeps ordinary `WebView2`; loading/switch masking is page-owned and matched to native WebView background
- candidate leaves `NewWindowRequested` native; custom app-tab action uses adapter-v7 cached DOM target only
- candidate broadens theme coverage, adds explicit theme reset, keeps top update path delta-only, and moves full Setup to Settings → Updates
- Owner-side Windows validation is still required before promoting the candidate
- filesystem mutation and `process.run` remain live-proven on their development lineage
- result auto-send still has one observed intermittent staged-but-not-auto-submitted failure
