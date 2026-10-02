# Current blockers and open risks

Updated: 2026-10-02 13:25 MSK

## BRIDGE-M1
No blocker. CLOSED.

## BRIDGE-M2
No blocker. CLOSED.

## BRIDGE-M3 live send confirmation
Current blocker is exact and reproducible in the latest bounded regression #175:

`Chat send failed: native-submit-not-confirmed`

The current native send sequence is:
1. adapter preflight accepts the composer;
2. Chromium/WebView2 `Input.insertText` inserts the bridge text and text match is verified;
3. adapter calls `form.requestSubmit()` and reports accepted;
4. native client waits up to 8 seconds for `nativeSendState().composerEmpty`;
5. if the composer is not observed empty, initialization fails with `native-submit-not-confirmed`.

The outstanding question is whether ChatGPT actually submits the message but the composer-empty condition is no longer a reliable confirmation, or whether `requestSubmit()` no longer triggers a real send in this state.

Do not write another broad E2E until that distinction is resolved.

## BRIDGE-M4 process safety
Windows Job Object Emergency STOP remains required before broad shell/process capability expansion.
