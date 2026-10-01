# DEC-0002 — Reliability roadmap before broad local capabilities

Date: 2026-10-01
Status: accepted
Authority: Owner directive

## Decision

Keep the embedded WPF/WebView2 + in-process C# Local Bridge architecture.

Before broad destructive/shell/process expansion, implement the approved sequence:
1. live E2E proof;
2. Web adapter hardening and fail-closed DOM behavior;
3. explicit bridge states and capability registry;
4. bounded large-result handling;
5. durable exactly-once execution and separate delivery recovery;
6. deterministic filesystem mutation primitives;
7. Windows Job Object Emergency STOP;
8. shell/process and later Git/Excel/browser/UI capability families.

## Constraints

Do not replace the architecture with Chrome-extension/localhost transport merely because reference projects use it. Such a migration requires separate evidence and Owner approval.
