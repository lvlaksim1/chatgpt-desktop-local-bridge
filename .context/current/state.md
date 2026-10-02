# Current state

Updated: 2026-10-02 05:44 MSK

- manager generation: 9
- product authority: `main`
- current verified product release: `dev-ea074e0@ea074e06bd4e959106f49f57cad1ac731597dac3`
- Owner installed release: `dev-ea074e0`
- adapter: v5
- native composer transport: Chromium/WebView2 `Input.insertText`
- current ChatGPT assistant selector: `[data-markdown-text-style='assistant-message']`
- current ChatGPT user selector: `[data-user-message-bubble='true']`
- legacy message selectors retained as fallbacks
- bridge protocol: strict `LOCAL_BRIDGE_REQUEST_V1 / LOCAL_BRIDGE_RESULT_V1`
- Windows paths in bridge JSON: use forward slashes
- BRIDGE-M1: CLOSED
- READY live proof: pc-runner-gateway #160 PASS
- fs.read_text live proof: #164 PASS
- final `dev-ea074e0` round-trip regression: #166 PASS
- BRIDGE-M2: ACTIVE
- immediate M2 focus: payload-free diagnostics for malformed bridge request candidates; no weakening of strict parser
