# Manager beliefs

## Active verified beliefs

1. The product repository is `lvlaksim1/chatgpt-desktop-local-bridge`.
   - source: live GitHub repository state
   - authority: verified-repository

2. Product authority is `main`; durable Project Manager state authority is `manager-state`.
   - source: Owner-approved manager installation on 2026-10-01
   - authority: owner-directive

3. Current product authority is `main@450b884423696b70905db394c68ddc45b2ba03ec`.
   - source: live GitHub repository state
   - authority: verified-repository

4. Current installable development release is `dev-450b884`, containing only `ChatGptDesktopLocalBridge-Setup.exe`. Its SHA-256 is `0757703080c8d334602b6d9882da9f565cd6d5361a88b05d17404c3bc0cb4cb0`.
   - source: GitHub Release and successful main workflow
   - authority: verified-repository / verified-ci

5. Repository storage policy is enforced in CI: generated binaries/packages are ignored by Git; ordinary development releases publish only the installer; obsolete portable-only dev releases/tags are deleted; at most the two newest installable dev prereleases are retained. Stable releases are not touched.
   - source: current product source and successful cleanup workflows
   - authority: verified-repository / verified-ci / owner-directive

6. The installer uses a stable Inno Setup AppId and installs for the current user under `%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`. Running a newer installer upgrades the existing installation in place rather than intentionally creating a parallel installation.
   - source: installer source + successful installer compilation
   - authority: verified-repository / verified-ci

7. ChatGPT authentication continuity is based on the dedicated WebView2 User Data Folder `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`, which is outside the application install directory. Installed builds continue to use this path across upgrades.
   - source: product source + Microsoft WebView2 UDF behavior
   - authority: verified-repository / trusted-external

8. Automatic cloning of a live Yandex Browser ChatGPT session into WebView2 is not the selected continuity mechanism. Cross-browser cookie/profile copying is not a robust contract and may be blocked by application-bound browser data protection; a dedicated persistent WebView2 profile avoids this dependency.
   - source: Yandex profile documentation, Chromium security documentation, WebView2 profile documentation
   - authority: trusted-external + manager-inference

9. The current MVP embeds `chatgpt.com` in WPF/WebView2 and uses injected JavaScript plus `window.chrome.webview.postMessage` to reach an in-process C# Local Bridge. It does not require an OpenAI API key, ChatGPT Work, a browser extension, or a localhost bridge server.
   - source: product source at current main
   - authority: verified-repository

10. Current implemented local tools are `system.info`, `fs.list`, and `fs.read_text`.
    - source: `ToolRouter.cs` at current main
    - authority: verified-repository

11. BRIDGE-M1 live evidence from the Owner on 2026-10-01: Diagnostics on both the prior portable build and the installed `dev-1d00606` baseline returned `Diagnostics failed: Local Bridge adapter is not injected.`
    - source: direct Owner live reports
    - authority: verified-runtime

12. A focused patch is now published in `dev-450b884`: `window.__localBridge` is registered before observer setup, and the MutationObserver targets the always-available `document` node instead of `document.documentElement`.
    - source: `main@450b884423696b70905db394c68ddc45b2ba03ec`
    - authority: verified-repository / verified-ci
    - status: implementation verified; root-cause hypothesis still requires live confirmation

13. Windows CI now checks `bridge-adapter.js` syntax with `node --check` before .NET restore/build.
    - source: current workflow and successful CI
    - authority: verified-repository / verified-ci

14. Owner approved the hardening roadmap derived from comparison with relevant public projects: generation detection, visible composer/send selection, send verification, fail-closed DOM handling, explicit bridge states, capability registry, bounded large results, durable exactly-once execution, separate result-delivery state, and Windows Job Object emergency STOP before shell/process expansion.
    - source: direct Owner directive on 2026-10-01
    - authority: owner-directive

15. External reference projects are evidence and design input, not project authority. Code from projects without an explicit compatible license must not be copied; concepts may be reimplemented independently.
    - source: engineering review on 2026-10-01
    - authority: manager-inference from verified repository metadata
