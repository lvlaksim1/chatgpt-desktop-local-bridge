# Project constraints

## RULE — Durable constraints

- Do not convert the product into an OpenAI API client unless the Owner explicitly changes direction.
- Do not make ChatGPT Work a required execution path.
- Do not use TinyFish for this project.
- Keep capability policy configurable outside hard-coded code ceilings. `AUTO / ASK / DENY` or later equivalent policy may define defaults without preventing explicit Owner configuration.
- Preserve transport-integrity checks even in a future unrestricted/full-trust permission profile.
- Treat `chatgpt.com` DOM automation as a compatibility surface that can drift; isolate selectors and fail closed when structural assumptions are not satisfied.
- Do not claim live end-to-end success from server-side CI alone.
- Avoid unnecessary GitHub Actions artifact storage. Development packages should be published through direct GitHub prerelease assets when needed.
- Stable/production release publication is Owner-gated.
- Do not expand to destructive/write/shell/process behavior until the reliability foundations declared in the active manager plan are implemented and verified.
- Do not copy code from third-party repositories without an explicit compatible license; design ideas may be independently reimplemented.
