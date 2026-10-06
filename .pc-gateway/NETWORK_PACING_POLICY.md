# Network pacing policy

Owner directive effective 2026-10-05.

This policy is a hard invariant for Local Bridge research, runner probes, experimental private transport code and future production transport code.

## Required pacing

- Every explicit scripted network/API/backend request MUST be serialized.
- There MUST be at least **5000 ms of quiet time after one explicit request completes before the next explicit request begins**.
- Parallel requests, request bursts and sub-5-second polling are prohibited.
- Retries follow the same minimum gap and SHOULD use increasing backoff where practical.
- The rule applies to:
  - `/api/*`
  - `/backend-api/*`
  - ChatGPT Library endpoints
  - Scheduled Tasks endpoints
  - signed upload/download URLs
  - GitHub and other external services used by research/automation
- Local-only operations (local files, JSON parsing, local process inspection, local Git checkout, hashing) are not network requests and are not rate-limited by this rule.

## Browser navigation

Do not introduce repeated page navigation/reload as a polling mechanism. Normal browser subresource loading caused by opening the signed-in application is not an explicit transport request, but probes MUST minimize unnecessary navigation and wait for the page to settle before issuing scripted backend requests.

## Implementation rule

New private-transport runner code must use a single serialized request gate. A compliant gate:
1. queues requests so only one is active;
2. records completion time;
3. waits until at least 5000 ms after the previous completion;
4. then starts the next request.

No research run may use legacy sub-second read-back loops.

## Legacy probes

Older probe scripts may contain 250-500 ms polling from experiments performed before this directive. They are historical evidence only and MUST NOT be executed again unless first upgraded to this policy.

## Failure behavior

Timeout or connection loss after a mutation remains `UNKNOWN_OUTCOME`:
- do not retry blindly;
- wait at least 5000 ms;
- perform authoritative read-back;
- reconcile state before any further mutation.
