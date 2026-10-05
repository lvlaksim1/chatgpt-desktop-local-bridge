# Manager plans

Manager generation: 21.
Updated: 2026-10-05 16:06 MSK

Product authority: `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Accepted UI baseline: `af6ac65306d5e91b84c48bb44fb7bc37da930053`.

## Immediate private-transport plan
1. Owner installs exact v3->v4 updater from release `private-transport-v4-8b2123c`.
2. Repeat only `Transport Probe -> Private Read Proof`.
3. Inspect actual HTTP statuses, elapsed times, response schemas and errors.
4. If reads succeed, capture current frontend task/library/file mutations.
5. If reads return 401/403 or similar, reproduce required same-origin request headers/account scope without persisting credentials.
6. If routes drift, use capture metadata to update narrow allowlisted endpoints.
7. Implement protocol-specific Tasks + Library/file methods only after observed contracts are stable.
8. Execute first no-composer/no-DOM-input E2E.
9. Then run durability/endurance matrix before any promotion.

## Other tracks
- PR #22 runtime foundation: Owner runtime validation pending.
- UI `4c92f81`: Owner runtime validation pending.
- PR #23 official ChatGPT-plan transport: live OAuth/model/inference pending.

Do not combine these promotion tracks.
