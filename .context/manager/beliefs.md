# Manager beliefs

## Active verified beliefs

1. The product repository is `lvlaksim1/chatgpt-desktop-local-bridge`.
   - source: live GitHub repository state
   - authority: verified-repository

2. Product authority is `main`; durable Project Manager state authority is `manager-state`.
   - source: Owner-approved manager installation on 2026-10-01
   - authority: owner-directive

3. Current product authority is `main@761f8369c0fa523834ba8c8baf819571684f5e98`. This commit only adds the Context Capsule discovery redirect; the current product-code/build baseline remains `977a504be19e2d21cb3c524275b003b9a6db7592`.
   - source: live GitHub repository state reconciled after manager bootstrap
   - authority: verified-repository

4. Development build `dev-977a504` is published from exact commit `977a504be19e2d21cb3c524275b003b9a6db7592`; its Windows x64 ZIP SHA-256 is `5ebf20caa9944a832ac7cba34c30b8ff4282ffbb1ef93ff228d3c4f8443edb1a`.
   - source: GitHub Release and successful Windows Build workflow
   - authority: verified-repository / verified-ci

5. The current MVP embeds `chatgpt.com` in WPF/WebView2 and uses injected JavaScript plus `window.chrome.webview.postMessage` to reach an in-process C# Local Bridge. It does not require an OpenAI API key, ChatGPT Work, a browser extension, or a localhost bridge server.
   - source: product source at current main
   - authority: verified-repository

6. Current implemented local tools are `system.info`, `fs.list`, and `fs.read_text`.
   - source: `ToolRouter.cs` at current main
   - authority: verified-repository

7. The protocol already has a fresh per-initialization session nonce, exact request/result envelopes, assistant-only interception, stable-message delay, request deduplication within the running process, permissions policy, audit logging, and a nonce-bound READY handshake.
   - source: current product source
   - authority: verified-repository

8. End-to-end operation against a signed-in live ChatGPT session on the Owner's Windows machine is not yet verified. The immediate external evidence gate is the first live diagnostics/handshake/`fs.read_text` test of build `dev-977a504`.
   - source: current development status
   - authority: verified-repository + owner interaction

9. Owner approved the hardening roadmap derived from comparison with relevant public projects: generation detection, visible composer/send selection, send verification, fail-closed DOM handling, explicit bridge states, capability registry, bounded large results, durable exactly-once execution, separate result-delivery state, and Windows Job Object emergency STOP before shell/process expansion.
   - source: direct Owner directive on 2026-10-01
   - authority: owner-directive

10. External reference projects are evidence and design input, not project authority. Code from projects without an explicit compatible license must not be copied; concepts may be reimplemented independently.
    - source: engineering review on 2026-10-01
    - authority: manager-inference from verified repository metadata
