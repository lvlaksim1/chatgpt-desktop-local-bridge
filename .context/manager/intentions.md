# Manager intentions and commitments

Manager generation: 23.
Updated: 2026-10-05 16:31 MSK

## Private transport
Current candidate: PR #29 / exp/chatgpt-private-transport-v5 / 95dd011593fd28b570831fc2995d26bef0691f27.

Live evidence:
- scheduled automations read: HTTP 200
- paused automations read: HTTP 200
- Library listing: HTTP 200
- Library storage usage: HTTP 200
- overall Private Read Proof: PASS

Commitments:
1. Treat read-plane as proven for the current Owner account/session.
2. Do not mutate through guessed endpoints or bodies.
3. Use the existing capture probe to observe exact current frontend mutation contracts first.
4. Promote only narrow task/library/file capabilities after live capture.
5. Preserve UNKNOWN_OUTCOME -> read-back -> reconcile for writes.
6. Require full request.json -> READY -> arm -> result.json -> ACK -> Desktop E2E with no composer/DOM input before any promotion.
7. Keep production Local Bridge/DOM transport unchanged as fallback.
