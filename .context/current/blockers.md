# Current blockers and open risks

Updated: 2026-10-05 16:06 MSK

## Private transport
The v3 live result cannot be used to judge backend availability because the probe returned the Promise object before fetch completion.

v4 fixes execution semantics, but the actual backend result is still unproven until Owner reruns `Private Read Proof`.

After v4 retest, possible next blockers are:
- endpoint drift;
- missing account/auth/device headers required by current ChatGPT frontend;
- task mutation body/arm semantics;
- Library/file upload/process/read/delete semantics;
- account/workspace stale-context fencing;
- ambiguous write recovery;
- complete no-DOM E2E and endurance behavior.

## Existing transport
Intermittent result staging without auto-submit remains open.

## Runtime/UI/MCP
PR #22 and UI candidate `4c92f81` need Owner runtime validation. MCP stdio child-process containment remains incomplete.

## ChatGPT-plan
PR #23 remains CI-only with live OAuth/model/inference and token lifecycle still unproven.
