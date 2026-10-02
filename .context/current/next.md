# Next actions

Updated: 2026-10-02 06:36 MSK

1. Do not rerun BRIDGE-M1 or BRIDGE-M2 unless later product changes touch those proven boundaries.
2. Continue BRIDGE-M3 with one coherent design for pending-result recovery:
   - persist a bounded replayable `LOCAL_BRIDGE_RESULT_V1` payload only after local execution completes;
   - do not rerun the tool when delivery state is `pending`;
   - bind recovery to the correct conversation/session;
   - delete or retire replay payload after delivery is committed.
3. Add centralized serialized-result bounds as part of the same delivery layer.
4. Add a single capability registry after delivery semantics are stable.
5. Keep changes on development branches with deterministic CI; avoid publishing a new Owner update for each internal sub-step.
6. When the coherent M3 slice is ready, publish one dev release, update the Owner PC once, and run one bounded live integration regression that checks local execution plus durable `completed/delivered` state.
