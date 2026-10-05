# Manager intentions and commitments

Manager generation: 20.
Updated: 2026-10-05 15:42 MSK

## Completed foundations

- BRIDGE-M0A through BRIDGE-M0E.
- BRIDGE-M1 CLOSED; canonical live transport baseline `ea074e0`.
- BRIDGE-M2 CLOSED as a feature milestone.

## Active — RUNTIME-FOUNDATION-V1

Candidate: `dev/runtime-foundation-v1`, draft PR #22, head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`.

Commitments:
1. Preserve durable request/result semantics and idempotency.
2. Preserve real AUTO/ASK/DENY permission enforcement.
3. Keep process execution inside Windows Job Object containment and retain emergency STOP.
4. Keep Local Tool Registry as the common capability boundary for native and MCP tools.
5. Keep repo/Git operations bounded, checkpointable and verifiable.
6. Do not merge PR #22 into `main` until Owner signed-in Windows runtime validation passes.

## Active — UI-SHELL-R1

Accepted baseline remains `0.2.8.0 / af6ac653`.
Candidate `4c92f81` remains CI-proven but Owner-runtime-pending.
Do not reintroduce CompositionControl or direct `ContextMenuTarget.LinkUri` without new independent live evidence.

## Active — SERVER-SIDE TRANSPORT R&D

Current user-facing candidate: `exp/chatgpt-private-transport-v3`, draft PR #27, head `70d3b2900cd72b2892dd4c75d000df4d2938e9be`, prerelease `private-transport-v3-70d3b29`.

Commitments:
1. Keep production DOM/Local Bridge transport unchanged while research is incomplete.
2. Use Scheduled Tasks as control-plane candidates and Library/files as data-plane candidates.
3. Prefer same-session page-context requests inside the signed-in WebView so credentials are not extracted or persisted.
4. Bind private/backend operations to a stable request context and fail stale when the WebView document/navigation/account context changes.
5. Treat mutating timeout/connection-loss as `UNKNOWN_OUTCOME`; read back authoritative state before retry.
6. Do not expose arbitrary internal HTTP fetch to the model. Promote only narrow task/library/file capabilities after evidence.
7. Require a full no-composer/no-DOM-input E2E before considering `ScheduledFileTransport` as optional production transport.
8. After E2E, run restart, duplicate, stale-ACK, relogin/navigation, network interruption, and large-payload/endurance tests before any promotion.
9. Keep PR #26 / `exp/private-transport-probe-v3` as alternate earlier evidence only; do not merge both divergent v3 branches.
10. Treat `exp/chatgpt-private-transport-v4` as a no-op pointer to v3 until it has unique reviewed changes.

## Active — CHATGPT-PLAN-TRANSPORT

Candidate: `exp/chatgpt-plan-transport`, draft PR #23, head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`.

Commitments:
1. Use the official Sign in with ChatGPT open-source OAuth/OIDC/PKCE path and public Responses endpoint.
2. Keep it isolated from the accepted WebView transport.
3. Require live Owner OAuth/model/inference proof before protected token persistence or product integration.
4. Require explicit Owner approval before it becomes a product mode/default.

## Operating directive

The Owner currently permits use of the standard GitHub connector until further notice. Never store credentials, cookies, tokens, or hidden reasoning in Git.
