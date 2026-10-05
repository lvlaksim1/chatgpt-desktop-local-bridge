# Manager goals

Manager generation: 20.
Updated: 2026-10-05 15:42 MSK

1. Deliver a reliable Windows desktop ChatGPT client that gives ordinary signed-in `chatgpt.com` conversations configurable native access to the local computer without requiring the OpenAI Platform API or ChatGPT Work.
2. Preserve the direct in-process architecture: WPF/WebView2 + injected adapter + native C# Local Bridge, avoiding a browser extension or localhost service unless later evidence shows a material need.
3. Keep local capabilities policy-driven through explicit metadata, AUTO/ASK/DENY permissions, cancellation, bounded execution, audit, and process containment.
4. Make the bridge reliable under DOM changes, streaming, restarts, duplicate delivery, large results, process trees, interrupted execution, and stale-context conditions.
5. Expand local capabilities through filesystem/process/Git/repo/MCP and later other tools only with evidence-backed safety and verification.
6. Keep builds reproducible and directly downloadable through GitHub Releases, preferring exact single-EXE incremental updaters and avoiding unnecessary Actions artifacts.
7. Preserve repository-backed Project Manager continuity across chat/runtime replacement and keep manager-state semantically synchronized with actual repository state.
8. Research a server-side alternative to DOM/composer result transport using Scheduled Tasks as control plane and ChatGPT Library/files as data plane, while retaining current Local Bridge as fallback until full Desktop E2E and endurance testing pass.
9. Treat alternative model transports (official ChatGPT-plan OAuth/Responses) as isolated experiments until live proof and explicit Owner architecture approval.
