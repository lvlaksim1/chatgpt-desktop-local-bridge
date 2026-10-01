# Procedural memory

## Product change workflow

1. Reconcile exact `main` head before editing.
2. Use a focused development branch/PR for nontrivial code changes.
3. Require Windows CI success before merge.
4. Merge only the verified head.
5. When Owner-side live validation is needed, create a self-contained `win-x64` development prerelease and record its exact commit and SHA-256.
6. Do not claim live ChatGPT behavior from CI alone.
7. Persist meaningful milestone/evidence changes to `manager-state` as one sealed generation.

## Web adapter debugging

Classify failures by layer before patching:
1. navigation/authentication;
2. adapter injection / native IPC;
3. assistant-message detection;
4. generation-state detection;
5. composer discovery/staging;
6. send initiation;
7. result delivery back to ChatGPT.

Prefer instrumentation and exact live evidence over broad selector rewrites.

## External project review

Use public projects to discover algorithms and failure modes. Verify repository license before copying code. When no explicit compatible license exists, reimplement concepts independently.
