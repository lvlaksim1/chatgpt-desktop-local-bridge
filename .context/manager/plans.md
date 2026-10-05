# Manager plans

Manager generation: 20.
Updated: 2026-10-05 15:42 MSK

Product authority: `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.

## 1. Runtime foundation

Candidate: PR #22 / `dev/runtime-foundation-v1` / `3f5ff0f`.

Next:
- perform Owner signed-in runtime validation of bridge restoration, ASK, file mutation, process execution, STOP, repo status/diff/map/checkpoint/verify and representative MCP behavior;
- reproduce the intermittent staged-but-not-auto-submitted result case;
- merge only after live proof and explicit promotion decision.

## 2. UI shell

Candidate: `4c92f81`.
Next:
- independently validate startup/loading, warm tab switching, downloads, safe custom context-menu path, theme/reset, updater placement and bridge auto-restore;
- preserve `af6ac653` as accepted baseline until PASS.

## 3. Scheduled Tasks + Library private transport

Research lineage:
- PR #24 `task-probe-49fb895`: task metadata discovery;
- PR #25 `scheduled-file-probe-6bb827b`: combined Tasks + Library discovery/replay;
- PR #26 `private-transport-probe-dd472e4`: alternate request-bound v3 implementation;
- PR #27 `private-transport-v3-70d3b29`: current user-facing v3 candidate.

Current next gate is live Owner testing of PR #27:
1. validate narrow read proof against the current signed-in account;
2. capture current frontend request shapes for task pause/resume/schedule/arm and Library/file operations;
3. verify same-session replay only for captured/allowlisted operations;
4. for writes, enforce `UNKNOWN_OUTCOME -> read-back -> reconcile`;
5. implement protocol-specific file create/upload/process/read/delete primitives only after the observed shapes are stable;
6. implement minimal mailbox control primitives only after current task mutation body/schema is confirmed;
7. run one complete E2E:
   `Desktop -> request.json -> Library/files -> mailbox READY -> arm -> Scheduled runtime -> result.json -> ACK -> Desktop read-back`;
8. verify `generation/seq/message_id` fencing and ACK-after-durable-result ordering;
9. then perform 100+ sequential round trips plus restart, duplicate, stale-ACK, navigation/relogin, network-loss and large-payload tests;
10. only after evidence classify the transport as REJECT / CONTROL-PLANE ONLY / OPTIONAL / DEFAULT.

Do not merge divergent PR #26 and PR #27 together mechanically. Reuse only individually proven ideas.

## 4. Official ChatGPT-plan transport

Candidate: PR #23 / `f2a3056`.
Next:
- Owner interactive OAuth sign-in;
- model discovery and one completed streamed inference;
- if PASS, design protected rotating refresh-token storage, account profiles, Local Tool Runtime function-call round trip and usage/error UX;
- any product integration remains Owner-gated.

## Cross-track rule

Do not combine unvalidated UI-shell, runtime-foundation, private-backend transport and ChatGPT-plan transport into one promotion. Each boundary must be validated and promoted independently.
