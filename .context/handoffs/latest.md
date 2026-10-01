# Latest handoff

Updated: 2026-10-01 18:50 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 3.
Product authority: `main@1d006065462d442e429478158e655e3edc5c7938`.

## Packaging/auth completed
Development release `dev-1d00606` contains `ChatGptDesktopLocalBridge-Setup.exe`.
The installer uses a stable application identity for in-place upgrades.
The WebView2 profile remains outside the install directory at `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`, so normal upgrades are designed to preserve ChatGPT sign-in.

## Live BRIDGE-M1 evidence
Diagnostics on the prior build returned `Local Bridge adapter is not injected`.
Source analysis suggests an early-document `document.documentElement` timing failure, but this is not yet live-verified.

## Required continuation
Install the new Setup as the persistent baseline, then resume the focused adapter bootstrap patch. Publish it through the same installer channel, upgrade over the installed version, confirm auth persistence, and rerun Diagnostics.

Do not claim BRIDGE-M1 success until READY and a local `fs.read_text` round trip are both proven.
