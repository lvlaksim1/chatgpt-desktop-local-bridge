# Current blockers and open risks

Updated: 2026-10-02 05:44 MSK

## BRIDGE-M1
No blocker. CLOSED with live READY and fs.read_text evidence on the Owner PC.

## BRIDGE-M2 reliability debt
Malformed bridge-request candidates are currently ignored silently by the adapter. When ChatGPT emits a bridge-looking response that is not valid protocol JSON, Diagnostics does not expose the parse reason. This can turn a simple protocol-format problem into a long timeout.

## DOM drift
ChatGPT DOM is not a stable public API. Current and legacy selectors are isolated in the adapter and must continue to fail closed. Live DOM success does not remove the need for explicit diagnostics.

## BRIDGE-M3 durability debt
Request dedupe is still RAM-only. Exactly-once local execution and exactly-once result delivery are separate problems. Durable request ledger and delivery recovery remain open.

## BRIDGE-M4 process safety debt
Mutating/process capabilities are not yet opened broadly. Windows Job Object Emergency STOP remains required before general shell/process expansion.
