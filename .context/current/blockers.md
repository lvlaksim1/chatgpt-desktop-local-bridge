# Current blockers and open risks

Updated: 2026-10-04 02:23 MSK

## Owner runtime gates
- UI-SHELL-R1 candidate `4c92f81` still requires signed-in Windows validation before it can replace accepted UI baseline `af6ac653`.
- Runtime foundation PR #22 still requires Owner-side live validation of WebView transport compatibility, ASK prompts, write/process execution, STOP behavior, and representative repo tools before any merge to `main`.

## Result delivery
At least one prior result was completely staged in the ChatGPT composer but not automatically submitted. Durable execution and result persistence do not by themselves close this DOM/send boundary.

## Repo-aware layer
`repo.map` v1 is intentionally dependency-free and bounded. It ranks text files and symbol-like declarations, but it does not yet implement Aider-style tree-sitter definition/reference graphs or PageRank. Do not represent it as semantic-completeness proof.

## MCP containment
The Local Tool Runtime can cancel an active MCP call, and MCP configuration is allowlisted/preconfigured with reduced environment inheritance. However the official SDK owns its stdio child-process lifecycle, so those server processes are not yet attached to the bridge's Windows Job Object. Treat broad unattended MCP-server execution as not fully contained.

## ChatGPT-plan transport experiment
PR #23 is compile/CI-proven only. Live OAuth, account-specific model discovery, streamed inference, rotating refresh-token storage, multi-account switching, usage-limit recovery, and Local Tool Runtime function-call round trips remain unproven. The experiment must not become the default transport without explicit Owner approval.

## Composition/WebView constraints
`WebView2CompositionControl` remains excluded after the prior deployment failure. Direct `CoreWebView2ContextMenuTarget.LinkUri` remains forbidden after the observed COM crash.
