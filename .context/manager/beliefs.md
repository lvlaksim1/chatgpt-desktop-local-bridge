# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main`; BRIDGE-M1 product release evidence: `dev-ea074e0@ea074e06bd4e959106f49f57cad1ac731597dac3`.
3. Manager-state authority: `manager-state`.
4. Owner machine is updated to `dev-ea074e0`; the prior intermediate installed baseline was `dev-450b884 / 0.1.28.0`.
5. Ordinary user-facing incremental updates are single EXE installers. ZIP delta packages are obsolete.
6. Delta updates validate the base, back up touched files, apply changed files, verify target hashes, roll back on failure, write `update-last.log`, preserve the WebView2 profile, and preserve normal uninstall behavior.
7. The bridge composer transport is proven on the Owner PC. JavaScript DOM mutation was not accepted by ChatGPT ProseMirror; native Chromium/WebView2 `Input.insertText` is accepted and is the supported bridge text injection mechanism.
8. Current ChatGPT DOM evidence uses `data-user-message-bubble="true"` for user messages and `data-markdown-text-style="assistant-message"` for assistant messages, with legacy selectors retained as fallbacks.
9. Adapter v5 detects nonce-bound READY and strict `LOCAL_BRIDGE_REQUEST_V1` envelopes, waits for a stable assistant message before dispatch, hides service messages, and preserves non-empty user drafts.
10. BRIDGE-M1 is CLOSED by live Windows evidence:
    - gateway #160: `Initialize Bridge -> Bridge ready. Session...` PASS;
    - gateway #164: `READY -> fs.read_text(C:/Windows/win.ini) -> successful local audit` PASS on `dev-72b6766`;
    - gateway #166: the same round trip PASS on product-fixed `dev-ea074e0`.
11. The failed fs.read probes exposed a concrete protocol/Markdown interaction: Windows paths containing backslashes can be altered by ChatGPT Markdown/JSON rendering. Using forward slashes (`C:/Windows/win.ini`) avoids the corruption.
12. `dev-ea074e0` fixes the product bootstrap so Windows path examples and rules require forward slashes in bridge JSON.
13. The next active milestone is BRIDGE-M2 Web adapter reliability hardening. The first evidence-backed debt is silent rejection of malformed bridge request candidates: today it manifested as a long audit timeout instead of an immediate diagnostic reason.
14. BRIDGE-M3 remains the durable execution foundation: explicit state machine, capability registry, bounded results, durable request ledger, and delivery recovery.
15. BRIDGE-M4 remains controlled mutating/process capabilities, including deterministic mutations and Windows Job Object Emergency STOP.
