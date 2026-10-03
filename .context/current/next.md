# Next actions

Updated: 2026-10-04 02:23 MSK

1. Let the current PR #22 control pipeline finish; Build and the expanded durable/runtime/repo regression stage are already PASS.
2. Prepare an installable PR #22 development candidate when Owner-side runtime validation is to begin; do not merge it to `main` first.
3. Validate PR #22 on the Owner Windows machine in this order: bridge restoration, read tools, ASK prompt, file mutation, bounded `process.run`, STOP of a spawned process tree, `repo.status`, `repo.diff`, `repo.map`, `repo.checkpoint`, and `repo.verify`.
4. Reproduce the prior staged-but-not-auto-submitted result case under the reconciled runtime candidate; harden transport if it still occurs.
5. Keep MCP opt-in. Add one disposable test server only for live validation, then verify discovery, ASK, call cancellation, and shutdown behavior. Do not broaden MCP process privileges until server containment is stronger.
6. Upgrade `repo.map` after the v1 runtime proof toward parser-backed definitions/references and dependency ranking; preserve strict output budgets and working-set/read-only distinctions.
7. Keep Git safety explicit: checkpoint before risky repository mutation and require build/lint/test evidence before a development stage is called complete. Consider an automatic checkpoint/verify orchestration layer only after the primitives are live-proven.
8. Live-test PR #23 separately using Owner interactive Sign in with ChatGPT. Validate issued client registration, ID-token checks, model discovery, and one completed streamed inference.
9. If PR #23 live proof passes, design protected rotating refresh-token storage, saved account profiles, function-tool round trips into the Local Tool Runtime, usage/error UX, and a clear WebView/native-mode switch.
10. Any promotion of the native ChatGPT-plan transport or merge into product-default architecture remains an explicit Owner decision.
11. UI-SHELL-R1 validation remains independent and must still be completed before changing the accepted UI baseline.
