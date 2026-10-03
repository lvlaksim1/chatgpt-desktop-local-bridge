# Manager plans

Manager generation: 18.
Updated: 2026-10-04 02:23 MSK

Product authority: `main` at `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
Canonical live transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`.
Accepted UI baseline: `0.2.8.0 / af6ac65306d5e91b84c48bb44fb7bc37da930053`.
UI validation candidate: `4c92f81d46b77f964b8e99fe25439058b9b835a1`.

## Runtime-foundation plan

Development candidate:
- branch `dev/runtime-foundation-v1`
- draft PR #22
- current head `3f5ff0fdda85165c38a977f2d29c7e893ecf3774`

Implemented slices:
- durable main lineage retained;
- M4 write/file/process tools reconciled;
- Windows Job Object kill-on-close and STOP;
- interactive ASK;
- 15-tool metadata registry;
- repo status/diff/map/checkpoint/verify;
- opt-in MCP stdio via official C# SDK;
- reduced MCP environment inheritance and ASK on calls;
- expanded Windows regression tests including a real temporary Git repo.

Evidence:
- run `37160870171`: complete Windows CI, publish, Setup, delta/updater and legacy uninstall E2E PASS for the application source at `b256a0c5`;
- run `37161576559`: after adding repo runtime coverage, Build PASS and durable/runtime/repo regression PASS at head `3f5ff0f`; later packaging is not needed to prove the test-only cleanup fix changes no application source.

Validation/promotion:
1. Keep PR #22 draft.
2. Produce an installable development candidate when live Owner testing starts.
3. Validate bridge/permission/process/STOP/repo behavior on the signed-in Windows runtime.
4. Re-test result auto-submit intermittency.
5. Only after PASS request/promote merge to `main` under Owner authority.

## Repo-aware follow-on
The v1 map is deliberately conservative. After live proof, evolve toward:
- parser-backed definitions/references;
- dependency graph ranking;
- explicit editable/read-only/whole-repo context scopes;
- deterministic token/character budgets;
- caching keyed by file modification/content state.

## MCP follow-on
Keep config empty by default. Next proof uses a disposable preconfigured server. Add stronger server-process containment before unattended expansion. Future HTTP/SSE/OAuth transports are optional and must not bypass Local Tool Runtime permissions/audit.

## ChatGPT-plan transport experiment

Development candidate:
- branch `exp/chatgpt-plan-transport`
- draft PR #23
- head `f2a3056b917a084c780c07f6f74ae6f3e7991c7b`
- CI run `37161271895`: PASS

The probe follows official OpenAI OSS/local-app SIWC: stable host ID, dynamic client registration, system-browser OAuth/OIDC/PKCE, state+nonce validation, ID-token signature/issuer/audience/lifetime validation, required `chatgpt.tokens.use.direct`, account model discovery, and `store:false` + `stream:true` public Responses inference.

Promotion gates:
1. Owner live sign-in.
2. account-specific model discovery.
3. completed streamed inference.
4. protected rotating refresh-token persistence and sign-out.
5. saved/multiple account UX.
6. Local Tool Runtime function-tool round trip.
7. usage/limit/revocation recovery.
8. explicit Owner architecture approval.

The ordinary WebView2 ChatGPT mode remains authoritative throughout the experiment.

## Cross-track rule
Do not combine unvalidated UI, runtime-foundation, and transport changes into one broad promotion. Validate and promote each boundary independently.
