# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main`; current product head after the first BRIDGE-M3 durability merge is `64152b68205a59e7df59d842c2acf972f717de33`.
3. Manager-state authority: `manager-state`.
4. Current verified and Owner-installed release: `dev-aea8ad2@aea8ad2971dd7e138434b60d5dfd90c63a0f4a34`.
5. Ordinary user-facing incremental updates are single EXE installers. ZIP delta packages are obsolete.
6. The bridge composer transport is proven on the Owner PC. Native Chromium/WebView2 `Input.insertText` is the supported bridge text injection mechanism.
7. Current ChatGPT DOM evidence uses `data-user-message-bubble="true"` for user messages and `data-markdown-text-style="assistant-message"` for assistant messages, with legacy selectors retained as fallbacks.
8. Adapter v7 executes only exact `LOCAL_BRIDGE_REQUEST_V1` envelopes, waits for stable streaming output, exposes payload-free protocol diagnostics, preserves ordinary user drafts, and may replace only bridge-owned stale drafts.
9. BRIDGE-M1 is CLOSED by live Windows evidence:
   - #160: `Initialize Bridge -> READY` PASS;
   - #164: `READY -> fs.read_text(C:/Windows/win.ini) -> local execution/audit` PASS;
   - #166: final M1 round-trip PASS on `dev-ea074e0`.
10. Windows paths in bridge JSON use forward slashes because backslashes can be altered by ChatGPT Markdown/JSON rendering.
11. BRIDGE-M2 is CLOSED. Gateway #168 passed the live reliability regression on Owner-installed `dev-aea8ad2`, including bridge-owned stale-draft recovery and a successful `fs.read_text` round trip.
12. BRIDGE-M3 is ACTIVE. The first durable execution foundation is merged to `main` at `64152b6`:
    - RAM-only request dedupe was replaced by an on-disk durable request ledger;
    - execution states are `reserved -> executing -> completed`;
    - delivery states are tracked separately as `notReady -> pending -> delivered`;
    - conflicting reuse of the same session/request id with different tool/args is fail-closed;
    - the ledger stores fingerprints/state, not request args or tool result payloads.
13. The deterministic durable-ledger regression and the full Windows build/update workflow passed before and after merge.
14. M3 delivery recovery remains intentionally incomplete: `completed/pending` is durable and prevents blind re-execution, but the result payload is not yet persisted/replayed after restart.
15. Remaining M3 scope includes bounded result transport, result-delivery recovery, capability registry, and explicit recovery semantics for session/conversation continuity.
16. BRIDGE-M4 remains controlled mutating/process capabilities, including deterministic mutations and Windows Job Object Emergency STOP.
