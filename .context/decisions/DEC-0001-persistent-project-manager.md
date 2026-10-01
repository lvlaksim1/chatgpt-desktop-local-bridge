# DEC-0001 — Persistent Project Manager and branch authority split

Date: 2026-10-01
Status: accepted
Authority: Owner directive

## Decision

Create persistent Project Manager `chatgpt-desktop-local-bridge-project-manager`.

Durable Project Manager identity, BDI state, memory, current views, and handoff state live on permanent branch `manager-state`.

Product truth remains on `main`.

The `main` branch carries only a Context Capsule discovery redirect and must not be treated as current manager state.

## Rationale

Manager continuity must survive chat/runtime replacement without mixing volatile manager state into normal product history.
