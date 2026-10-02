# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main`; current head is `9461fffbacceceeb6f1404bebf76d521e4578c01`.
3. Manager-state authority: `manager-state`.
4. Latest published development release: `dev-31e823e@31e823ef7854a18bb2ad10e94ec71c51814628eb`.
5. Owner-installed release is still `dev-85c714c@85c714c9b46df2c8ea5329b2d265953d9735ee3f`, confirmed by pc-runner-gateway update #169. No later successful owner update is recorded.
6. BRIDGE-M1 and BRIDGE-M2 are CLOSED.
7. BRIDGE-M3 product code has advanced beyond generation 10:
   - pending result envelopes are durably persisted after local execution;
   - replay state distinguishes reserved, uncertain executing, pending completed, and already delivered requests;
   - pending delivery recovery is bound to the originating ChatGPT conversation;
   - already delivered results are not replayed and their persisted payload is retired;
   - result transport is centrally bounded to 256 KiB and oversize results become explicit bounded errors without local re-execution;
   - one capability registry is authoritative for tool dispatch, permission capability mapping, metadata, and bootstrap exposure.
8. The current adapter is v8+ and can detect whether a specific bridge result is already present in the active conversation.
9. The first live crash-recovery attempt #170 failed at chat-submit confirmation. Later M3 live attempts #171-#173 also failed in the harness path: #171 used the wrong installed-base expectation, #172 encountered a non-empty composer, and #173 exited during the validation script. These are not successful M3 live proof.
10. A clean bounded M3 live regression now exists at `main@9461fff`. It targets `dev-31e823e` and verifies a real `fs.read_text` followed by durable ledger `completed/delivered`, correct conversation binding, and retired delivered payload.
11. A bounded owner update task from `dev-85c714c` to `dev-31e823e` exists at `main@dd26c48`.
12. CI for the update task and the final bounded M3 live regression is currently running. Do not create additional live-test variants while those runs are unresolved.
13. The next correct action after green CI is exactly one owner update to `dev-31e823e`, then exactly one bounded M3 live regression.
14. BRIDGE-M4 remains controlled mutating/process capabilities after M3 closure, including deterministic mutations and Windows Job Object Emergency STOP.
