# Episode: Local Bridge write/process capability and local GitHub CLI bootstrap

Date: 2026-10-02
Persistent manager: `chatgpt-desktop-local-bridge-project-manager`

## Context

The Owner wanted Local Bridge to become the normal control path for repository/GitHub work, using local CLI rather than ChatGPT connector calls. The proven transport reference is source `ea074e06bd4e959106f49f57cad1ac731597dac3`.

## Filesystem mutation

Branch: `m4-write-tools-ea074e0`

Commits:
- `c13781814ade651ee6b7d51f37a4b37ad997491b`
- `826674c158df8ad868ec85823adbc2b38bb1653d`
- release workflow: `38c2aca554268a07343b8e1a6c805e787b3971f9`

Tools:
- `fs.write_text`
- `fs.append_text`
- `fs.write_file`

All reuse the existing `fs.write_text` capability.

Prerelease: `dev-ea074e0-write-tools`

Artifacts:
- `ChatGptDesktopLocalBridge-ea074e0-write-tools-Setup.exe`
  - SHA-256 `f081f9b58c78b963025545241e0d009f5d840cc9c5f0e915647ed974952676a0`
  - 51,450,714 bytes
- `ChatGptDesktopLocalBridge-Update-from-benchmark-ea074e0.exe`
  - SHA-256 `786837c95e5e25bf0ab0202486fd8c4d28d250aff3055c8c256f2a03a470cc49`
  - 2,189,440 bytes

Live proof: `fs.append_text` appended `тестовый ответ` to `D:/test/file.txt` and returned `ok:true`.

## Process execution

Branch: `m4-process-run-write-tools`

Commits:
- `a2c00c7619506c5aa0e98a523fc4b14ad255d141`
- `ef2ac99a73cdc3c9a8fba8965d3a6ee9714e2753`
- release workflow: `cdb78c9d5f1a230d012f26fca1e391be5c5c23f9`

`process.run` uses executable + structured argument list, optional cwd, bounded timeout/output, redirected stdout/stderr, no stdin, and kills the process tree on timeout. It reuses the existing `process.start` capability.

Prerelease: `dev-process-run`

Artifacts:
- `ChatGptDesktopLocalBridge-process-run-Setup.exe`
  - SHA-256 `ceec3c9c0204624979ee344b7a26a59821247618bc43645c9493f4dfbcf35d60`
  - 51,456,305 bytes
- `ChatGptDesktopLocalBridge-Update-from-dev-ea074e0-write-tools.exe`
  - SHA-256 `03fde14068ca7159ed8be3c7f3b9d6b8d861f9cff58b5ae20bca82cf35d61fd6`
  - 2,193,352 bytes

## Live CLI proof

Bridge session for final proof: `44e0b51dfdde46a2be9c8c200b6e6829`.

- `git.exe --version`: exit 0, Git 2.55.0.windows.5.
- `gh.exe --version`: exit 0, GitHub CLI 2.98.0.
- `gh.exe auth status`: exit 0, active account `lvlaksim1`, HTTPS Git protocol; reported scopes include `repo` and `workflow`.
- `gh repo view lvlaksim1/chatgpt-desktop-local-bridge --json nameWithOwner,visibility,defaultBranchRef`: exit 0; repository visible, default branch `main`.

No credential/token value is stored here.

## Transport observation

For `gh --version`, process execution succeeded and the complete result was staged in the ChatGPT composer, but automatic submission failed; the Owner sent it manually. Later `gh auth status` and `gh repo view` results auto-delivered. Therefore process execution is proven while result auto-submit remains intermittently weak.

## Owner decision

Future GitHub work should normally use Local Bridge with local `git`, `gh`, and PowerShell. A dedicated GitHub implementation inside the bridge is not needed initially. Persistent terminal/ConPTY is not needed yet. ChatGPT connector use is exceptional.

## Efficiency lesson

Local commands completed quickly; chat round trips dominated elapsed time. Prefer one bounded noninteractive work stage per bridge request when safe.
