# Project goals

## REQUIREMENT — Primary goals

- Provide a Windows-native desktop ChatGPT experience with direct configurable access to local files, processes, applications, and later higher-level automation.
- Use ordinary `chatgpt.com` and the Owner's normal ChatGPT subscription rather than the OpenAI API.
- Avoid dependence on ChatGPT Work for local-computer access.
- Keep the local execution channel native to the application rather than requiring a browser extension or localhost bridge service.
- Make capability permissions externally configurable. Restrictive defaults are acceptable; permanent hard-coded authority ceilings are not.
- Expand capabilities incrementally while preserving replay safety, crash recovery, auditability, and an emergency stop path for process execution.
- Produce self-contained Windows builds that the Owner can download and test directly.
