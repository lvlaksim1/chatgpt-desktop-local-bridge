# Procedural memory

## Product change workflow

1. Reconcile exact product-authority head before editing.
2. Use a focused development branch/PR for nontrivial code changes.
3. Require Windows CI success before merge.
4. Merge only the verified head.
5. When Owner-side live validation is needed, create a self-contained `win-x64` development prerelease and record exact commit and SHA-256.
6. Do not claim live ChatGPT behavior from CI alone.
7. Persist meaningful milestone/evidence changes to `manager-state` as one sealed generation.

## UI/WebView recovery workflow

1. Start from the latest Owner-accepted runtime baseline, currently `0.2.8.0` / `af6ac653`.
2. Change one fundamental WebView/UI behavior per prerelease where practical.
3. Do not change the WebView control class merely to hide a rendering symptom unless deployment dependencies have been proven on the Owner system.
4. For context-menu link handling, prefer a target captured before the native context-menu callback through the injected DOM adapter/cache. Never rely on direct `ContextMenuTarget.LinkUri` in the current lineage.
5. Treat context-menu, theme, and link enhancements as optional: catch boundary failures and leave native behavior intact.
6. Preserve bridge restore, background tab preloading, WebView profile/session continuity, and updater continuity unless a change explicitly targets one of them.
7. CI validates source/build/package integrity. Owner-side Windows testing validates signed-in ChatGPT rendering, downloads, flashes, context-menu timing, and dynamic theme behavior.
8. Promote the new commit as the next baseline only after Owner validation. If it fails, revert that step rather than layering another speculative fix on top.
9. Keep rejected release commits as historical evidence, but do not merge the rejected lineage wholesale.

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

## Local Bridge CLI workflow

1. Prefer direct `git.exe` or `gh.exe` through `process.run` when one executable can complete the step.
2. For several dependent commands forming one bounded work stage, use one noninteractive PowerShell call rather than one bridge round trip per trivial command.
3. Use structured process arguments whenever possible.
4. Set finite timeout and output cap.
5. Do not run commands requiring interactive stdin; `process.run` does not provide stdin.
6. Never print, persist, or ask the Owner to paste GitHub tokens; rely on existing local credential state.
7. Treat exit code/stdout/stderr/timed-out metadata as execution evidence.
8. Distinguish local command success from ChatGPT result-delivery success.
9. Prefer Local Bridge CLI over the ChatGPT GitHub connector when the bridge is available; use the connector only when explicitly requested or the local path is unavailable.
10. Continue to apply Project Manager approval gates for destructive/high-impact operations even though the local CLI can technically perform them.

## External project review

Use public projects to discover algorithms and failure modes. Verify repository license before copying code. When no explicit compatible license exists, reimplement concepts independently.
