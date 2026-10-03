# Manager intentions and commitments

Manager generation: 18.
Updated: 2026-10-04 02:23 MSK

## Completed
- BRIDGE-M0A through BRIDGE-M0E
- BRIDGE-M1: CLOSED; canonical live transport baseline `ea074e0`
- BRIDGE-M2: CLOSED as a feature milestone

## Active — UI-SHELL-R1
Owner-established accepted recovery baseline remains `0.2.8.0 / af6ac653`.
Candidate `4c92f81` is built and CI-proven but is not accepted until Owner-side signed-in Windows validation passes.
Do not reintroduce CompositionControl or direct `ContextMenuTarget.LinkUri` without new independent runtime evidence.

## Active — RUNTIME-FOUNDATION-V1 / BRIDGE-M3+M4 reconciliation
Authorized objective: execute the sequence durable execution → permissions → Job Object/STOP → Tool Registry → repo-aware tools → Git safety/verification → MCP.

Current development candidate is `dev/runtime-foundation-v1` / PR #22, head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`.

Implemented commitments:
1. Preserve main-line durable request/result ledger semantics.
2. Reconcile proven `fs.write_text`, `fs.append_text`, `fs.write_file`, and `process.run` into the main-derived development lineage.
3. Make ASK real and interactive; retain AUTO/ASK/DENY as the policy boundary.
4. Contain bridge-owned process trees with Windows Job Objects and expose an emergency STOP that cancels generic active work.
5. Maintain one metadata-backed registry for model-visible local tools.
6. Provide bounded repo status/diff/map/checkpoint/verify primitives.
7. Use Git checkpoints and verification as safety/evidence primitives rather than silently mixing Owner changes with agent changes.
8. Expose MCP as an optional extension behind the same permission layer, never as a bypass around it.
9. Do not merge PR #22 into `main` before Owner runtime validation.

## Active — CHATGPT-PLAN-TRANSPORT experiment
Owner authorized the experiment as the last stage of the development sequence.
The current experiment is `exp/chatgpt-plan-transport` / draft PR #23, head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`.

Commitments:
1. Use OpenAI's official Sign in with ChatGPT open-source flow and public Responses endpoint, not the historical private backend endpoint observed in gptme.
2. Keep the experiment isolated from the accepted WebView transport.
3. Do not persist OAuth access/refresh/ID tokens in the first probe.
4. Require live Owner OAuth/model/inference proof before adding protected token persistence.
5. Require explicit Owner architecture approval before native ChatGPT-plan transport can become a product mode or default.

## Operating directive
The Owner's newer directive permits the standard GitHub connector until further notice; it supersedes the older connector-exception rule. Never store credentials, cookies, OAuth tokens, or hidden reasoning in Git.
