# Next actions

Updated: 2026-10-03 06:10 MSK

1. Owner installs the delta `ChatGptDesktopLocalBridge-Update-from-ui-shell-af6ac65.exe` from prerelease `ui-shell-4c92f81`.
2. Validate startup first; if startup fails, collect fresh Windows Application/.NET Runtime evidence before changing code.
3. Validate initial loading/black-area behavior and loaded-tab switching.
4. Confirm background tabs still preload and Local Bridge still restores automatically.
5. Validate ordinary download links.
6. Validate right-click “Открыть в новой вкладке” and confirm no process crash.
7. Validate broader unified theme plus “Сбросить тему”.
8. Verify the top updater is delta-only and full Setup is available only under Settings → Updates.
9. On full PASS, promote `4c92f81` as the next accepted UI baseline and close the implementation portion of UI-SHELL-R1.
10. On any FAIL, map the regression to `f30424d`, `0ff4286b`, `ee6ce6e`, or `4c92f81` and repair/revert only that slice.
11. After UI validation, proceed to Diagnostics, then transport hardening, fine-grained ASK permissions, tool expansion, and production hardening.
12. Continue BRIDGE-M3/M4 reconciliation and process-containment work without losing the `ea074e0` transport invariant.
