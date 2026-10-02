# Current blockers and open risks

Updated: 2026-10-02 06:36 MSK

## BRIDGE-M1
No blocker. CLOSED.

## BRIDGE-M2
No blocker. CLOSED with deterministic diagnostics coverage and live reliability regression #168.

## BRIDGE-M3 delivery recovery
The durable ledger now prevents blind re-execution across process state loss, but a `completed/pending` record does not yet contain a replayable result payload. A restart after local execution but before ChatGPT delivery therefore preserves the fact that execution happened, but cannot yet complete delivery automatically.

Recovery must also be bound to the correct ChatGPT conversation/session so a pending result can never be injected into an unrelated chat.

## BRIDGE-M3 bounded results
Transport-level serialized result bounds are not yet centralized. Tool-specific limits exist, but result delivery needs one explicit upper bound before larger capability families are added.

## BRIDGE-M3 capability registry
Tool execution and capability mapping are still switch-based and bootstrap exposure is still manually listed. A single registry remains required before capability expansion.

## BRIDGE-M4 process safety
Mutating/process capabilities are not yet opened broadly. Windows Job Object Emergency STOP remains required before general shell/process expansion.
