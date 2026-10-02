# Next actions

Updated: 2026-10-02 05:44 MSK

1. Do not rerun BRIDGE-M1 unless a later product change touches the proven boundary.
2. Implement BRIDGE-M2 adapter protocol diagnostics:
   - detect bridge-request marker candidates;
   - retain strict exact-envelope execution;
   - record payload-free rejection reason;
   - expose last protocol event/failure via `health()`.
3. Add a bounded deterministic parser/diagnostics check.
4. Run one short live regression only if the adapter product code changes.
5. Seal M2 evidence, then start BRIDGE-M3 durable execution foundation.
