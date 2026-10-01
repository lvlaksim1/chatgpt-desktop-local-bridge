# Episode — persistent manager bootstrap

Date: 2026-10-01

The Owner explicitly requested a persistent manager with its own Context Capsule for `lvlaksim1/chatgpt-desktop-local-bridge`.

At bootstrap:
- product authority was `main@977a504be19e2d21cb3c524275b003b9a6db7592`;
- development release `dev-977a504` had passed Windows CI and was being installed by the Owner for the first live end-to-end test;
- the Owner approved the engineering roadmap derived from comparison with ChatGPTDesktopApp, chatgpt-local-hands, and chatgpt-local-agent;
- the immediate responsibility was BRIDGE-M1 live validation, followed by adapter hardening and durable execution foundations.

The manager was created as `chatgpt-desktop-local-bridge-project-manager` with product authority on `main` and durable state authority on `manager-state`.
