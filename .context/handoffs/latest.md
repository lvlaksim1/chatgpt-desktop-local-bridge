# Latest handoff

Updated: 2026-10-04 02:23 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 18.
Product authority: `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Manager-state authority: `manager-state`.
Canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.
UI candidate: `4c92f81d46b77f964b8e99fe25439058b9b835a1`, still Owner-runtime-pending.

## Owner directive executed

The Owner authorized implementation of:
durable execution → permissions → Job Object/STOP → Tool Registry → repo-aware tools → Git safety + verification → MCP layer → ChatGPT subscription/plan transport experiment.

## Runtime foundation

Branch: `dev/runtime-foundation-v1`
Draft PR: #22
Head: `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`

Implemented:
- reconciled M4 write/process tools into the durable main-derived lineage;
- `ProcessExecutionManager` with bounded redirected IO, timeout/cancellation, Windows Job Object kill-on-close and tree-kill fallback;
- interactive WPF ASK confirmation and default safe permission profile;
- generic STOP cancellation surfaced in the toolbar;
- metadata-backed registry with 15 tools;
- `repo.status`, `repo.diff`, bounded `repo.map`, `repo.checkpoint`, `repo.verify`;
- checkpoint storage under LocalAppData, without mutating the repository;
- official C# MCP SDK stdio client, empty config by default, server/tool allowlisting, reduced environment inheritance, `mcp.call=ASK`;
- real Windows regression coverage for process containment plus a temporary Git repository exercising status/diff/map/checkpoint/verify.

Evidence:
- `37160870171`: full pipeline PASS for current application source before the later test-only commits;
- first repo-smoke run exposed only a Windows test-cleanup issue after the suite had already printed PASS;
- cleanup was hardened in test-only commit `3f5ff0f`;
- `37161576559`: Build PASS and expanded durable/runtime/repo regression PASS.

Do not merge to `main` yet. Signed-in Owner runtime proof remains required.

## ChatGPT-plan transport experiment

Branch: `exp/chatgpt-plan-transport`
Draft PR: #23
Head: `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`
CI: run `37161271895` PASS.

Important discovery: OpenAI now documents an official Sign in with ChatGPT flow for open-source/local apps. It can authorize eligible ChatGPT plan usage without an API key or client secret and uses the public `https://api.openai.com/v1/responses` endpoint. The docs explicitly say not to use ChatGPT private `backend-api` endpoints for this flow.

The isolated probe implements OAuth/OIDC/PKCE, dynamic client registration, loopback callback, state/nonce and ID-token validation, required plan scope, model discovery, and streamed `store:false` inference. It persists registration identity only and deliberately does not persist access/refresh/ID tokens yet.

Live interactive OAuth/model/inference proof is still pending. No product-mode migration is approved.

## Remaining high-value risks
- intermittent WebView result auto-submit;
- Owner runtime validation of PR #22;
- MCP server child-process containment beyond call cancellation;
- parser/graph-quality repo map;
- SIWC refresh-token protection, multi-account UX, tool round-trip and usage recovery;
- independent UI-SHELL-R1 Owner validation.

## Operating note
The Owner currently permits use of the standard GitHub connector until further notice.
