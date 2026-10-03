# Experimental ChatGPT plan transport

Status: **experimental / non-production / not wired into the desktop UI**

This branch tests a second transport for ChatGPT Desktop while keeping the accepted WebView2 transport unchanged.

## Why this experiment changed

The original architectural reference from `gptme` used a ChatGPT backend endpoint. OpenAI now documents an official open-source/local-app flow called **Sign in with ChatGPT**.

For eligible ChatGPT Plus/Pro users, an open-source local application can:

1. register dynamically as a public OAuth client,
2. authenticate with ChatGPT using OAuth 2.0 + OIDC + PKCE,
3. request `chatgpt.tokens.use.direct`,
4. receive an OAuth access token without an API key or client secret,
5. send eligible inference requests to the public Responses endpoint,
6. have usage count against the user's ChatGPT plan/credits according to OpenAI's current rules.

The official docs explicitly say to use:

- authorization: `https://auth.openai.com/api/accounts/authorize`
- token exchange: `https://auth.openai.com/api/accounts/oauth/token`
- resource: `https://api.openai.com/v1`
- model discovery: `GET https://api.openai.com/v1/models`
- inference: `POST https://api.openai.com/v1/responses`

For this flow, OpenAI explicitly says **not** to use ChatGPT `backend-api` endpoints.

Primary references reviewed 2026-10-04:

- https://developers.openai.com/siwc/token-sharing-open-source
- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/token-reference
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

## Probe

Project:

`experiments/ChatGptPlanTransportProbe/ChatGptPlanTransportProbe.csproj`

The probe deliberately remains separate from the WPF application. It validates the transport before any product architecture change.

Current probe behavior:

1. creates and persists a stable UUID-based `ext_agent_host_id`;
2. creates PKCE verifier/challenge, OAuth state, and OIDC nonce;
3. starts a loopback listener on `127.0.0.1`;
4. opens the system browser at OpenAI authorization;
5. performs first-time dynamic client registration with `dynamic_agent_client`, or reuses the previously issued client ID;
6. validates callback state;
7. exchanges the authorization code without a client secret;
8. validates the returned ID token signature against OpenAI JWKS plus issuer/audience/lifetime/nonce;
9. requires the granted `chatgpt.tokens.use.direct` scope;
10. lists account-visible models;
11. streams one `store:false`, `stream:true` Responses request until `response.completed`.

Run:

```powershell
dotnet run --project .\experiments\ChatGptPlanTransportProbe\ChatGptPlanTransportProbe.csproj -- "Say exactly: ChatGPT plan transport works."
```

Optional model:

```powershell
dotnet run --project .\experiments\ChatGptPlanTransportProbe\ChatGptPlanTransportProbe.csproj -- --model <MODEL_SLUG> "hello"
```

## Credential policy

This first probe intentionally does **not persist access, refresh, or ID tokens**.

It persists only:

- stable host ID;
- issued OAuth client ID;
- validated subject identifier;
- email, if returned.

Path:

`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\experiments\chatgpt-plan-transport\registration.json`

That means every new probe process performs OAuth again. This is intentional for the first security boundary test.

A production implementation must add protected token storage, rotating-refresh-token handling, multiple saved ChatGPT account registrations, explicit sign-out/revocation handling, and usage UI before this transport can be considered for integration.

## Preview constraints that affect our architecture

Current OpenAI requirements for ChatGPT-plan Responses requests include:

- `store:false`
- `stream:true`
- send needed history in `input`
- do not rely on `previous_response_id` for HTTP conversation persistence
- several normal Responses fields and hosted tools are unavailable
- client-side function/custom tools are supported
- hosted MCP/connectors, native computer use, file search and Code Interpreter are not available on this route

Therefore the natural architecture remains:

```text
ChatGPT-plan Responses transport
            |
            v
      Local Tool Runtime
       /      |      \
 filesystem process   MCP
            |
      permissions/audit
```

Local Bridge tools remain local. The subscription transport changes the model transport, not the authority/safety boundary.

## Promotion gate

Do not merge this experiment as the default transport merely because it compiles.

Before product adoption it requires:

1. Owner live OAuth validation;
2. successful model discovery;
3. successful streamed inference;
4. token refresh + protected storage design;
5. tool-call round-trip proof with Local Tool Runtime;
6. usage-limit/error recovery;
7. UX for switching between ordinary WebView ChatGPT and native ChatGPT-plan mode;
8. explicit Owner approval of the architecture change.

The accepted WebView2 path remains authoritative until those gates are satisfied.
