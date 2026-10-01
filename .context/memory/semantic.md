# Semantic memory

## Architecture lessons admitted 2026-10-01

- The direct embedded-WebView architecture remains the preferred product direction: WebView2 already provides native IPC through `window.chrome.webview.postMessage`, so a Chrome extension + localhost HTTP bridge is unnecessary for the current desktop product.
  - source: current product architecture plus comparison with public projects
  - authority: verified-repository + manager-inference

- Real ChatGPT DOM compatibility must be treated as a live integration boundary. Successful compilation cannot prove selector correctness, generation detection, composer behavior, authentication popups, downloads, or actual message submission.
  - source: current product evidence and public WebView/extension implementations
  - authority: verified-repository + trusted-external

- Robust bridge submission should detect active generation, choose visible controls, preserve user drafts, verify that submission actually started, and fail closed on structural DOM mismatch.
  - source: comparative engineering review accepted by Owner
  - authority: owner-directive + trusted-external

- Exactly-once execution and exactly-once result delivery are distinct reliability problems. Durable request identity/recovery is required before destructive or process capabilities can be considered robust.
  - source: comparative engineering review accepted by Owner
  - authority: owner-directive + trusted-external

- Windows Job Objects with kill-on-close are the preferred containment primitive for future bridge-owned process trees and emergency STOP.
  - source: comparative engineering review accepted by Owner
  - authority: owner-directive + trusted-external

## Third-party licensing note

- `nwn900/ChatGPTDesktopApp` declares ISC.
- `mozg4D/chatgpt-local-agent` declares MIT.
- `mikhail494/chatgpt-local-hands` had no explicit repository license at review time; do not copy its code into this project without later license verification.
