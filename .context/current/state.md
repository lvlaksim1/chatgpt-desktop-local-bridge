# Current state

Updated: 2026-10-04 02:23 MSK

- manager generation: 18
- product authority: `main`
- current verified authoritative product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- manager-state authority: `manager-state`
- canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`
- BRIDGE-M1: CLOSED
- BRIDGE-M2: CLOSED
- UI-SHELL-R1: ACTIVE; candidate `4c92f81d46b77f964b8e99fe25439058b9b835a1` remains CI-proven but Owner-runtime-pending; accepted UI baseline remains `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`
- RUNTIME-FOUNDATION-V1: ACTIVE validation candidate on `dev/runtime-foundation-v1`, head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`, draft PR #22
- PR #22 reconciles the durable main lineage with the proven write/process slice and adds real ASK confirmation, Windows Job Object process containment, generic STOP cancellation, a metadata-backed 15-tool registry, repo-aware tools, Git checkpoint/verification primitives, and an opt-in MCP stdio layer
- latest repo-aware regression run `37161576559`: Build PASS; durable/runtime regression PASS, including temporary-Git status/diff/map/checkpoint/verify and Job Object STOP. Packaging continues on the same run; previous full pipeline for the same application source, run `37160870171`, passed publish/installer/update/uninstall E2E
- MCP uses official `ModelContextProtocol.Core 2.2.0`; local server list is empty by default; only preconfigured server IDs may be called; `mcp.read=AUTO`, `mcp.call=ASK`; broad environment inheritance is disabled
- `repo.map` is a bounded first-generation heuristic map, not yet the full tree-sitter/PageRank-quality design learned from Aider
- CHATGPT-PLAN-TRANSPORT: isolated experiment on `exp/chatgpt-plan-transport`, head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`, draft PR #23
- PR #23 uses OpenAI's official Sign in with ChatGPT open-source flow: OAuth/OIDC/PKCE + public `/v1/models` and `/v1/responses`; no API key and no private ChatGPT backend endpoint
- PR #23 Windows CI run `37161271895`: PASS; live OAuth/model/inference validation still requires interactive Owner sign-in
- the accepted/default product transport remains ordinary `chatgpt.com` in WebView2 with in-process native IPC; no transport migration has been approved
- intermittent result staged-but-not-auto-submitted behavior remains open
- Owner directive currently permits use of the standard GitHub connector until further notice
