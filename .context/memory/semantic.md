# Semantic memory

## Architecture lessons admitted 2026-10-01

- The direct embedded-WebView architecture remains preferred: WebView2 already provides native IPC through `window.chrome.webview.postMessage`, so a browser extension + localhost service is unnecessary for the current product.
- Real ChatGPT DOM compatibility is a live integration boundary; compilation cannot prove selector correctness, generation detection, composer behavior, authentication UI, downloads, or actual submission.
- Exactly-once execution and exactly-once result delivery are separate reliability problems; durable request identity/recovery is required before mutating/process capability can be considered robust.
- Windows Job Objects with kill-on-close remain the preferred containment primitive for future bridge-owned process trees and emergency STOP.

- source: legacy-v2-state
- authority: legacy-unverified
## Local Bridge lessons admitted 2026-10-02

- Complete application behavior at source `ea074e0`, not merely one submit call, is the canonical live transport baseline. Same-day Owner proof establishes that later transport failures are application regressions.
- Filesystem mutation and local process execution can be layered onto the proven `ea074e0` transport while preserving a working request/result path.
- A generic structured `process.run` primitive is sufficient for initial Git/GitHub/PowerShell access; no dedicated GitHub implementation inside the bridge is currently needed.
- Result staging and result submission are distinct steps: a complete result can already be present in the composer even when automatic send confirmation fails.
- Interactive elapsed time is dominated by chat round trips, not local command execution. Safe dependent CLI work should be grouped into one bounded noninteractive stage where practical.
- Owner operating decision: future GitHub manipulation should normally use Local Bridge with local `git`, `gh`, and PowerShell. ChatGPT connector use is exceptional.

- source: legacy-v2-state
- authority: legacy-unverified
## UI shell lessons admitted 2026-10-03

- `0.2.8.0` / `af6ac653` is the Owner-accepted recovery baseline after the 0.2.9/0.2.10 UI regression sequence.
- A compile-successful `WebView2CompositionControl` substitution is not deployment-safe by inference. On the Owner's Windows 10 system it triggered a startup `FileNotFoundException` for `Microsoft.Windows.SDK.NET, Version=10.0.17763.10`.
- `CoreWebView2ContextMenuTarget.LinkUri` has a timing-sensitive COM boundary: direct access produced `0x8000000E` and terminated the application. Context-link resolution must not depend on that property.
- Optional WebView UI enhancements must be isolated from application survival: context menu, theming, and link helpers should fail closed rather than terminate the WPF process.
- WebView visual correctness is a live-runtime property. CI cannot validate flashes, black surfaces, signed-in downloads, dynamic ChatGPT theme coverage, or context-menu timing.
- When several foundational WebView behaviors change in one release, a runtime regression becomes expensive to isolate. The recovery workflow should advance through narrowly scoped prereleases, promoting only Owner-validated baselines.
- A rejected release may still contain useful design ideas, but it is evidence, not a source branch to merge wholesale into the accepted baseline.

- source: legacy-v2-state
- authority: legacy-unverified
## Third-party licensing note

- `nwn900/ChatGPTDesktopApp` declares ISC.
- `mozg4D/chatgpt-local-agent` declares MIT.
- `mikhail494/chatgpt-local-hands` had no explicit repository license at review time; do not copy its code without later license verification.

- source: legacy-v2-state
- authority: legacy-unverified
## UI recovery candidate admitted 2026-10-03

- A page-owned fixed paint shield inside ordinary WebView2 is the current recovery strategy for masking navigation and tab-reveal paint transitions while avoiding the deployment failure of the CompositionControl experiment. It is implemented and CI-proven but not yet Owner-runtime-proven.
- Keeping initialized WebViews warm while switching only their parent containers is the current tab-preload strategy. Hidden ready tabs are armed with an internal switch shield before their next reveal.
- Native link/download semantics and custom app-tab navigation are intentionally separated: normal WebView behavior is left unintercepted, while explicit app-tab opening depends on a pre-captured DOM target.
- The recovery stage was committed in isolated slices before the release commit so runtime failures can be mapped back to a narrow change set.

- source: legacy-v2-state
- authority: legacy-unverified
## gptme architectural reference admitted 2026-10-04

Provenance: public `gptme/gptme` master and official `gptme.org` documentation reviewed 2026-10-04. External project is reference evidence only, not project authority.

- `gptme` v0.34.0 is an MIT-licensed local-first agent runtime with a provider-independent chat loop, persistent conversation logs, extensible ToolSpec/plugin/hooks layers, shell/Python/file/web/computer tools, checkpoints, context compression, autonomous-agent scaffolding, MCP/ACP integration, and a Tauri desktop wrapper.
- Its durable-agent model is strongly aligned with Context Capsule's separation principle: the persistent agent is a version-controlled workspace containing identity, tasks, journal, knowledge, lessons and history; the harness/runtime and model/provider are replaceable execution layers.
- Useful patterns for Local Bridge are architectural rather than a wholesale runtime replacement: capability metadata/allowlists, hook-based lifecycle controls, explicit conversation/workspace recovery, bounded output handling, prompt-injection hygiene, sandbox/blast-radius separation, contextual lessons, and deterministic persistence barriers.
- gptme's Windows desktop packaging is not equivalent to the current Local Bridge design: its desktop app starts/reuses a localhost `gptme-server`, while our accepted architecture intentionally keeps the bridge in-process through WebView2 IPC.
- gptme currently documents a distinct `openai-subscription` provider for personal development use with ChatGPT Plus/Pro. Its implementation uses OAuth 2.0 + PKCE, local refresh-token persistence, and posts Responses-format requests to `https://chatgpt.com/backend-api/codex/responses` with a ChatGPT account header. This is not the OpenAI Platform API and does not depend on the embedded ChatGPT DOM.
- The subscription provider is therefore a potentially important alternative transport/reference for the project's no-Platform-API goal, but it is not equivalent to preserving ordinary `chatgpt.com` conversations/UI. Adoption would be a product-architecture decision and remains Owner-gated; do not silently replace the accepted WebView2 + native Local Bridge path.
- gptme's own documentation advises keeping humans at irreversible/public boundaries and reducing unattended-agent blast radius with isolated environments, scoped credentials and version-controlled work. This is compatible with the Local Bridge policy direction toward configurable permissions and stronger process containment.

- source: legacy-v2-state
- authority: legacy-unverified
## Witsy and Aider architectural references admitted 2026-10-04

Provenance: public `Kochava-Studios/witsy` main, `Aider-AI/aider` main, and their project documentation reviewed 2026-10-04. External projects are reference evidence only, not project authority.

### Witsy
- Witsy is an Electron/TypeScript desktop AI assistant and universal MCP client. It separates Electron main-process capabilities from renderer UI through an explicit preload/IPC API. This reinforces the Local Bridge design principle that privileged local capabilities should stay behind a narrow native boundary rather than be exposed directly to web/UI code.
- Its MCP layer is a useful reference for future Local Tool Runtime extensibility: persistent MCP clients, stdio/SSE/streamable-HTTP transports, per-server tool selection, cached tool discovery, deterministic name-collision mappings, per-tool timeouts, cancellation through AbortController, OAuth support, and conversion of MCP schemas into model-facing tool metadata.
- Tool selection semantics are explicit: null means all tools, [] means no tools, and a list means an allowlist. This is a useful configuration model, but Local Bridge should retain its stronger AUTO/ASK/DENY permission direction rather than copy this literally.
- Witsy agents are saved multi-step workflows. Each run has a durable run id/status/messages; steps can consume prior outputs as `output.N`, select model/tools/agents/doc repositories independently, support structured output, persist progress between steps, and propagate cancellation. This is a useful reference for bounded workflow execution, not a replacement for Project Manager BDI.
- Witsy's long-term memory is vector retrieval over stored facts. This is useful as a retrieval technique but is weaker than Context Capsule for authoritative/project state; vector memory must not become authority.
- Witsy uses localhost HTTP as a secondary integration surface for CLI/webhooks/OAuth callbacks. Our accepted in-process WebView2 IPC remains preferred for the core bridge; localhost remains optional, not foundational.
- Witsy is AGPL-3.0. Architectural ideas may be studied, but code must not be copied into this project unless AGPL obligations are deliberately accepted and Owner-approved.

### Aider
- Aider's strongest reusable concept is the repo map: it parses source with tree-sitter, extracts definitions/references, builds a repository symbol graph, ranks context (including PageRank-style relevance), and renders only high-value code structure within an explicit token budget. This is a strong candidate for a future repo-aware Local Bridge tool/context service.
- Aider distinguishes editable chat files, read-only files, and the broader repository map. This is preferable to dumping an entire repository into model context and suggests an explicit scoped-context layer for future coding workflows.
- Git is used as a safety and provenance layer: pre-existing dirty changes can be checkpointed/committed separately before model edits, model edits are then committed separately, and undo/diff/history remain ordinary Git operations. The transferable principle is to isolate user state from agent state before mutation; automatic commits themselves should remain policy/configurable in our project.
- Aider validates edits by running lint/test loops and can feed failures back into another repair iteration. This is a useful generic pattern for Local Bridge: mutate -> verify -> optionally repair, with explicit evidence before completion.
- Aider's architect/editor split separates reasoning about the solution from deterministic production of file edits. This maps well to a future Manager -> bounded Editor/Executor delegation model and can reduce malformed edits.
- Aider selects edit protocols per model (whole file, search/replace diff, fenced diff, simplified unified diff). The broader lesson is that transport/edit format should be adaptable independently of the reasoning layer.
- Aider supports web-chat workflows without an LLM API: it packages selected files + read-only files + repo map into browser-pastable context and can apply a copied web-model response locally. This is directly relevant to our no-Platform-API architecture: Local Bridge can remain connected to ordinary ChatGPT UI while a repo-aware local subsystem prepares context and safely applies edits.
- Aider is Apache-2.0 licensed, so compatible code reuse is possible with required notices if later justified; prefer learning the architecture before copying implementation.

- source: legacy-v2-state
- authority: legacy-unverified
## Official ChatGPT-plan transport supersession admitted 2026-10-04

Provenance: OpenAI Sign in with ChatGPT documentation reviewed 2026-10-04; Owner-authorized transport experiment.

- OpenAI now documents an official open-source/local-app path for eligible ChatGPT plan usage using OAuth 2.0/OIDC + PKCE and dynamic public-client registration, without requiring the user to provide an OpenAI API key or a client secret.
- For this project, that official path supersedes the historical private `chatgpt.com/backend-api/codex/responses` implementation observed in gptme. The private backend remains historical reference evidence only and must not be used for the current experiment.
- The official inference path is the public `https://api.openai.com/v1/responses` endpoint with the ChatGPT-plan OAuth bearer token. Current OSS-flow HTTP requests require `store:false` and `stream:true`; the client sends needed conversation history in `input`.
- The transport changes how the model is reached; it does not replace the Local Tool Runtime safety boundary. Local filesystem/process/repo/MCP capabilities remain governed by local permissions, cancellation, audit, and containment.
- Current Owner directive permits the standard GitHub connector until further notice; this supersedes the earlier connector-exception operating rule.

- source: legacy-v2-state
- authority: legacy-unverified

## Scheduled + Library Desktop transport probe v2 admitted 2026-10-04

- Owner-authorized R&D continues from the server-side Scheduled Tasks + Library experiments documented in `chatgpt-desktop-scheduled-file-transport-research.md`.
- New isolated branch: `exp/scheduled-file-transport-probe-v2`; draft PR #25.
- Release commit: `6bb827b007111c225ba17cf8c3900ddc86ae4b1a`; prerelease tag `scheduled-file-probe-6bb827b`.
- The Desktop probe now classifies both Scheduled Tasks and ChatGPT Library backend traffic, records sanitized endpoint metadata plus JSON field/type shapes, and keeps exact captured URL/body only in process memory.
- Selected captured requests can be replayed through page-context fetch in the already signed-in WebView2 session. Read requests run directly; mutating requests require an explicit human confirmation. This replay is diagnostic UI only and is not exposed as a general model tool.
- Persistent diagnostic logs do not store query values, request/response bodies, cookies, bearer material, or sensitive headers.
- Release workflow `37165435366`: PASS, including build, runtime-foundation regression, publish, full Setup, exact delta from `task-probe-49fb895`, and prerelease publication.
- Incremental updater: `ChatGptDesktopLocalBridge-Update-from-task-probe-49fb895.exe`, size 2,317,646 bytes, SHA-256 `4653b9fb4d95bc9324947644a8729c01a82a54c23213b644a4c315a8a5d6d8c6`.
- Production Local Bridge transport remains unchanged. The remaining proof is live Owner-side discovery/replay of actual Tasks and Library operations, followed by a protocol-specific minimal E2E implementation if the backend shapes are stable.

- source: legacy-v2-state
- authority: legacy-unverified

## Private transport probe v3 admitted 2026-10-04

- Owner-authorized implementation based on `chatgpt-desktop-github-private-transport-research.md`.
- Isolated branch: `exp/private-transport-probe-v3`; draft PR #26.
- Release commit: `dd472e44077e962ddb4b96e21d65de14ddb4b183`; prerelease tag `private-transport-probe-dd472e4`.
- Added request/document binding around private backend calls: each operation captures current `https://chatgpt.com` origin plus a per-document token and rejects a response when the WebView document/origin changes mid-flight.
- Added narrow read-only clients for current observed endpoint hypotheses: Scheduled Tasks list filters, latest backing run, Library listing, and Library storage usage. These use same-origin page-context fetch and are not exposed as a general arbitrary URL tool.
- Mutation replay now returns explicit `UNKNOWN_OUTCOME` when a write may have been dispatched but no authoritative response is known. The UI instructs not to retry and offers safe read-back via current Scheduled Tasks or Library state.
- Diagnostic persistence remains schema/metadata only. Exact captured URL/body and read-only response bodies are memory-only; cookies/auth headers/tokens are not written to diagnostic logs.
- Release workflow `37166164652`: build, runtime regression, publish, full Setup, exact delta from `scheduled-file-probe-6bb827b`, and prerelease publication PASS.
- Incremental updater: `ChatGptDesktopLocalBridge-Update-from-scheduled-file-probe-6bb827b.exe`, 2,325,075 bytes, SHA-256 `9bee619e8a494fccd8c29a241c91caae53138a94137add8f852635fe2db3ce82`.
- Full Setup: `ChatGptDesktopLocalBridge-private-transport-probe-Setup.exe`, 51,636,166 bytes, SHA-256 `4d94fbfcf80ad4ebe64c1434fee441ef21bb2c476b9252099dfb81016d37f8ae`.
- Production Local Bridge transport and `main` remain unchanged. Next live gate is to validate the endpoint hypotheses against the Owner account, capture exact task mutation bodies, then implement protocol-specific file upload + task mutation E2E.

- source: legacy-v2-state
- authority: legacy-unverified
