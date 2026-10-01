# Current blockers and open risks

Updated: 2026-10-01 18:15 MSK

## Immediate gate
BRIDGE-M1 cannot be declared complete until the current packaged build is exercised in a real signed-in ChatGPT session on the Owner's Windows machine.

## Known integration risk
The product depends on the live `chatgpt.com` DOM. Selectors and submission behavior can drift independently of successful C# compilation.

## Reliability debt before mutating tools
Current request deduplication is process-memory-only. It is adequate for the read-only MVP test but not sufficient for destructive, write, shell, or process actions across restart/crash boundaries.

## Process-control debt
There is not yet a Windows Job Object containment/emergency-STOP layer. Shell/process capabilities must not be treated as production-ready before that foundation exists.

## Packaging
No current CI/package blocker. Development prerelease `dev-977a504` is available.
