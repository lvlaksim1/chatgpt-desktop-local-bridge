# Latest handoff

Updated: 2026-10-02 16:20 MSK

Persistent manager: `chatgpt-desktop-local-bridge-project-manager`.
Manager generation: 14.
Product authority: `main`.
Current known product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.

## Critical new canonical evidence
The Owner manually installed the exact-morning benchmark application based on source commit `ea074e06bd4e959106f49f57cad1ac731597dac3` and repeated the morning Local Bridge test successfully.

Observed full PASS:
- prompt requested `fs.read_text` for `C:/Windows/win.ini`;
- Local Bridge executed the read and application UI reported `fs.read_text completed in 2 ms.`;
- `LOCAL_BRIDGE_RESULT_V1` was delivered into the same conversation;
- ChatGPT then produced a normal answer with the actual file contents, including `[Mail]` and `MAPI=1`.

This is now the canonical transport acceptance benchmark.

## Diagnosis
The same mechanism still works in the current ChatGPT/service environment when running the exact morning application. Therefore the live failure in later builds is a post-`ea074e0` application regression.

A narrow restoration of `form.requestSubmit()` on current code was insufficient, so the investigation must cover the complete transport/bootstrap/adapter delta rather than the submit call alone.

## Next task
Preserve the complete `ea074e0` transport behavior and reintroduce later M2/M3 changes incrementally, requiring the unchanged `win.ini` benchmark to remain visibly PASS. Resume final M3 durable validation only after that invariant is restored on current code.
