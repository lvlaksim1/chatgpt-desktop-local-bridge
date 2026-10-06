# Next actions

Updated: 2026-10-06 05:32 MSK

1. Update the phased E2E evidence path to capture the executed backing run before Phase C restoration, including a causal run id/timestamp plus bounded safe content.
2. Start a fresh probe_id using the already-proven UTC one-shot scheduling semantics.
3. Run Phase A once; wait without polling; run one Phase B observation.
4. In Phase B, verify that the captured backing run belongs to the fresh probe and explicitly test whether worker-side direct Library result creation is available.
5. Run Phase C cleanup/restoration regardless of PASS/pending/failure.
6. If direct Library write succeeds, complete the result-file path and prove the first full round trip.
7. If direct Library write is unavailable, evaluate the narrowest first-party ChatGPT return channel without using an external file intermediary or composer/DOM input.
8. Persist the resulting durable finding immediately and only then proceed to READY/ACK/correlation fencing or the next transport hypothesis.
