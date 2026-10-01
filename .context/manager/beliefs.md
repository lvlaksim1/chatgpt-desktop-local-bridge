# Manager beliefs

## Active verified beliefs

1. The product repository is `lvlaksim1/chatgpt-desktop-local-bridge`.
   - source: live GitHub repository state
   - authority: verified-repository

2. Product authority is `main`; durable Project Manager state authority is `manager-state`.
   - source: Owner-approved manager installation on 2026-10-01
   - authority: owner-directive

3. Current product authority is `main@1d006065462d442e429478158e655e3edc5c7938`.
   - source: live GitHub repository state
   - authority: verified-repository

4. Development release `dev-1d00606` is published from exact commit `1d006065462d442e429478158e655e3edc5c7938`. It contains both an upgradeable per-user Windows installer and a portable ZIP.
   - installer: `ChatGptDesktopLocalBridge-Setup.exe`
   - installer SHA-256: `1ee7a76720ec9938dbdb59401200dcae79fb3e3a6d23380cf3d604f9e386260d`
   - source: GitHub Release and successful Windows Build workflow
   - authority: verified-repository / verified-ci

5. The installer uses a stable Inno Setup AppId and installs for the current user under `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`. Running a newer installer upgrades the existing installation in place rather than intentionally creating a parallel installation.
   - source: installer source + successful installer compilation
   - authority: verified-repository / verified-ci

6. ChatGPT authentication continuity is based on the dedicated WebView2 User Data Folder `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`, which is outside the application install directory. Both portable and installed builds use this same path.
   - source: product source + Microsoft WebView2 UDF behavior
   - authority: verified-repository / trusted-external

7. Automatic cloning of a live Yandex Browser ChatGPT session into WebView2 is not the selected continuity mechanism. Cross-browser cookie/profile copying is not a robust contract and may be blocked by application-bound browser data protection; a dedicated persistent WebView2 profile avoids this dependency.
   - source: Yandex profile documentation, Chromium security documentation, WebView2 profile documentation
   - authority: trusted-external + manager-inference

8. The current MVP embeds `chatgpt.com` in WPF/WebView2 and uses injected JavaScript plus `window.chrome.webview.postMessage` to reach an in-process C# Local Bridge. It does not require an OpenAI API key, ChatGPT Work, a browser extension, or a localhost bridge server.
   - source: product source at current main
   - authority: verified-repository

9. Current implemented local tools are `system.info`, `fs.list`, and `fs.read_text`.
   - source: `ToolRouter.cs` at current main
   - authority: verified-repository

10. BRIDGE-M1 live evidence from the Owner on 2026-10-01: pressing Diagnostics on `dev-977a504` returned `Diagnostics failed: Local Bridge adapter is not injected.`
    - source: direct Owner screenshot/live report
    - authority: verified-runtime

11. Source analysis indicates a likely early-document bootstrap defect: the injected script calls `observer.observe(document.documentElement, ...)` during document-created execution, when `document.documentElement` may still be null; this can terminate the script before `window.__localBridge` is registered.
    - source: source-code reconciliation after the live failure
    - authority: manager-inference
    - status: hypothesis pending patched live verification

12. Owner approved the hardening roadmap derived from comparison with relevant public projects: generation detection, visible composer/send selection, send verification, fail-closed DOM handling, explicit bridge states, capability registry, bounded large results, durable exactly-once execution, separate result-delivery state, and Windows Job Object emergency STOP before shell/process expansion.
    - source: direct Owner directive on 2026-10-01
    - authority: owner-directive

13. External reference projects are evidence and design input, not project authority. Code from projects without an explicit compatible license must not be copied; concepts may be reimplemented independently.
    - source: engineering review on 2026-10-01
    - authority: manager-inference from verified repository metadata
