# Manager goals

1. Deliver a reliable Windows desktop ChatGPT client that gives ordinary `chatgpt.com` conversations configurable native access to the local computer without the OpenAI API or ChatGPT Work.
2. Preserve the direct in-process architecture: WPF/WebView2 + injected adapter + native C# Local Bridge, avoiding a browser extension or localhost service unless later evidence shows a material need.
3. Keep local capabilities policy-driven rather than permanently hard-coded: restrictive defaults are allowed, but the Owner can expand permissions through normal configuration.
4. Make the bridge reliable under real ChatGPT DOM changes, streaming, restarts, duplicate delivery, large results, process trees, and interrupted execution.
5. Expand from the read-only MVP toward filesystem mutation, shell/process, Git, Excel, browser/UI, and other local capabilities only after the required reliability foundations are verified.
6. Keep builds reproducible and directly downloadable through GitHub Releases without unnecessary GitHub Actions artifact storage.
7. Preserve repository-backed Project Manager continuity across chat/runtime replacement.
