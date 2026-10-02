# Current blockers and open risks

Updated: 2026-10-02 16:20 MSK

## BRIDGE-M1
No blocker. CLOSED.

## BRIDGE-M2
No blocker as a milestone. Its post-M1 adapter changes must nevertheless be checked against the newly pinned `ea074e0` transport invariant.

## BRIDGE-M3 live transport regression
The blocker is no longer ambiguous.

Exact same-day manual evidence proves that application source `ea074e0` still completes the full bridge flow:
`ChatGPT prompt -> LOCAL_BRIDGE_REQUEST_V1 -> fs.read_text -> LOCAL_BRIDGE_RESULT_V1 -> final ChatGPT answer`.

The Owner observed `fs.read_text completed in 2 ms.` and the final answer contained the actual `win.ini` contents.

Current/post-`ea074e0` code fails before READY in the same benchmark. Restoring only `form.requestSubmit()` did not restore behavior. Therefore the regression is in the broader post-`ea074e0` transport/bootstrap/adapter delta.

Do not diagnose this primarily through send-button disabled state, composer-empty state, or generic network timeout. Those are secondary diagnostics only.

## Environmental instability
Owner Internet and ChatGPT service are intermittently unstable and may add review latency. Account for this in timeouts, but do not use it to explain away a deterministic contrast between current code and the same-day working `ea074e0` baseline.

## BRIDGE-M4 process safety
Windows Job Object Emergency STOP remains required before broad shell/process capability expansion.
