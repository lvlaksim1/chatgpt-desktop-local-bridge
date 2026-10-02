# Current state

Updated: 2026-10-02 06:36 MSK

- manager generation: 10
- product authority: `main`
- current product head: `64152b68205a59e7df59d842c2acf972f717de33`
- current verified / Owner-installed release: `dev-aea8ad2@aea8ad2971dd7e138434b60d5dfd90c63a0f4a34`
- adapter: v7
- native composer transport: Chromium/WebView2 `Input.insertText`
- bridge protocol: strict `LOCAL_BRIDGE_REQUEST_V1 / LOCAL_BRIDGE_RESULT_V1`
- Windows paths in bridge JSON: forward slashes
- BRIDGE-M1: CLOSED
- BRIDGE-M2: CLOSED
- M2 live reliability proof: pc-runner-gateway #168 PASS
- BRIDGE-M3: ACTIVE
- M3 durable request-ledger foundation: merged to `main@64152b6`
- durable execution states: `reserved -> executing -> completed`
- durable delivery states: `notReady -> pending -> delivered`
- durable-ledger regression: PASS
- post-merge main CI: PASS
- result payload replay for `completed/pending`: not yet implemented
- no additional Owner update is planned until the next coherent M3 slice is ready
