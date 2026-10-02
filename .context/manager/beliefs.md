# Manager beliefs

## Active verified beliefs

1. Product repository: `lvlaksim1/chatgpt-desktop-local-bridge`.
2. Product authority: `main`; current known head is `6e2a0b54b727c5474bad40ac038f727a39cceb8d`.
3. Manager-state authority: `manager-state`.
4. BRIDGE-M1 and BRIDGE-M2 remain CLOSED as milestones, but the proven M1 transport path must now be treated as a compatibility baseline for all later work.
5. BRIDGE-M3 durable execution/delivery foundation remains implemented on `main`, but final live validation is blocked by a regression in the ChatGPT send/handshake path.
6. The Owner manually installed the exact-morning benchmark build whose application source is the proven `ea074e06bd4e959106f49f57cad1ac731597dac3` state.
7. On 2026-10-02 at approximately 16:18 MSK the Owner manually repeated the morning `fs.read_text` scenario and visually confirmed a full real round trip:
   - prompt sent in ChatGPT;
   - Local Bridge request produced;
   - `C:/Windows/win.ini` read locally;
   - `LOCAL_BRIDGE_RESULT_V1` delivered into the same conversation;
   - ChatGPT produced a normal human-readable answer containing the file contents, including `[Mail]` and `MAPI=1`;
   - application status showed `fs.read_text completed in 2 ms.`.
8. This manual revalidation is the canonical live transport PASS. It is stronger evidence than composer/button/DOM heuristics.
9. Because the exact morning application still works now with the same service/profile environment, the current failure is a regression introduced after `ea074e0`, not evidence that ChatGPT stopped supporting the mechanism and not adequately explained by network instability.
10. Restoring only `form.requestSubmit()` on current code was insufficient: current release `dev-265d63b` still failed to obtain `LOCAL_BRIDGE_READY_V1`. Therefore the regression is somewhere in the broader post-`ea074e0` send/bootstrap/adapter changes, not necessarily the submit call alone.
11. Future transport work must proceed from the complete proven `ea074e0` behavior, preserving it while later M2/M3 changes are reintroduced incrementally.
12. Owner reports unstable Internet and intermittent ChatGPT additional-review delays. These remain relevant to timeout interpretation, but they do not override the exact same-day `ea074e0` PASS.
13. BRIDGE-M4 remains controlled mutating/process capabilities after M3 live closure.
