# Current blockers and open risks

Updated: 2026-10-02 17:35 MSK

## BRIDGE-M1
No blocker. CLOSED.

## BRIDGE-M2
No blocker as a milestone. Any later adapter hardening must preserve the `ea074e0` transport invariant.

## BRIDGE-M3 reconciliation
The exact `ea074e0` transport path is live-proven, while later `main` contains substantial M3 durability work. These lineages are not yet reconciled. Do not overwrite M3 durability wholesale and do not reintroduce the post-`ea074e0` transport regression.

## Result auto-submit intermittency
At least one process-run result (`gh --version`) was fully inserted into the ChatGPT composer but automatic submission failed, requiring manual send. Later results delivered automatically. This is a transport/confirmation weakness, not a local process execution failure.

## BRIDGE-M4 process containment
`process.run` is intentionally live and authorized via the existing process capability, giving the bridge broad execution power under the current user account. It uses bounded timeout/output and kills the process tree on timeout, but does not yet use a Windows Job Object with kill-on-close. Before broad unattended shell/process expansion, stronger bridge-owned process containment remains required.

## Permission semantics
Because `process.run` can directly invoke ordinary executables such as PowerShell, process-execution permission is the effective gate for such use. Keep this explicit in future permission UX/design.

## Interactive latency
Local commands complete quickly; multiple ChatGPT request/result turns dominate wall-clock latency. Batch logically related noninteractive commands inside one bounded process stage where safe.
