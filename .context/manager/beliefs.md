# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main`; current head is `9461fffbacceceeb6f1404bebf76d521e4578c01`.
3. Manager-state authority: `manager-state`.
4. Latest published development release and current Owner-installed release: `dev-31e823e@31e823ef7854a18bb2ad10e94ec71c51814628eb`.
5. Owner update to `dev-31e823e` is confirmed by pc-runner-gateway #174 PASS.
6. BRIDGE-M1 and BRIDGE-M2 are CLOSED.
7. BRIDGE-M3 product code includes durable execution state, persisted bounded pending result envelope, replay-safe classification, originating-conversation recovery, delivered-result suppression/payload retirement, a 256 KiB transport bound, and one central capability registry.
8. Adapter v8 is current in `dev-31e823e`.
9. Final bounded M3 live regression #175 did not pass. It failed during normal bridge initialization with application status `Chat send failed: native-submit-not-confirmed`.
10. This failure occurs after native text insertion and accepted form submission, when the application waits up to 8 seconds for the composer to become empty. It is therefore currently a send-confirmation/submit-boundary problem, not evidence that the durable ledger itself failed.
11. Earlier M3 live probes #170-#173 are superseded by #175 for current diagnosis.
12. Repository CI for the exact updater and bounded M3 regression is green.
13. A redundant update request #176 was created while reconciling parallel state and has been closed as duplicate; do not repeat the update.
14. Immediate work is to analyze `native-submit-not-confirmed` using existing evidence and the current send implementation before writing any new live probe.
15. BRIDGE-M4 remains controlled mutating/process capabilities after M3 closure.

16. Owner reports an unstable Internet connection and intermittent ChatGPT service behavior, including delayed additional review of some requests. Therefore a single live failure at a ChatGPT/network boundary (queueing, send confirmation, READY/assistant-response timeout) is ambiguous evidence and must not be promoted directly to a product defect.
17. For safe/idempotent live validation, retry the exact same bounded scenario once before changing product code when the first failure is plausibly transport/service-related. Repeated identical failure at the same boundary is stronger product evidence. This rule does not authorize blind retry of mutating or execution-uncertain local operations.
