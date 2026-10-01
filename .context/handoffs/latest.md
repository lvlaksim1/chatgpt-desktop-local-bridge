# Latest handoff

Updated: 2026-10-01 19:02 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 4.
Product authority: `main@724a64b7f1ccc0ec92cd95fb511ecf1acb74ca95`.

## Packaging/auth completed
Development release `dev-1d00606` contains only `ChatGptDesktopLocalBridge-Setup.exe`.
The installer uses a stable application identity for in-place upgrades.
The WebView2 profile remains outside the install directory at `%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`, so normal upgrades are designed to preserve ChatGPT sign-in.

## Storage hygiene completed
CI now publishes installer-only dev releases and automatically:
- removes redundant portable ZIP assets;
- deletes portable-only dev prereleases and matching tags;
- retains at most the two newest installable dev prereleases;
- leaves stable releases untouched.

The first cleanup completed successfully; current Releases contains only `dev-1d00606` with its Setup.exe.

## Live BRIDGE-M1 evidence
Diagnostics on the prior build returned `Local Bridge adapter is not injected`.
Source analysis suggests an early-document `document.documentElement` timing failure, but this is not yet live-verified.

## Required continuation
Resume the focused adapter bootstrap patch. Publish it through the same installer channel, upgrade over the installed version, confirm auth persistence, and rerun Diagnostics.

Do not claim BRIDGE-M1 success until READY and a local `fs.read_text` round trip are both proven.
