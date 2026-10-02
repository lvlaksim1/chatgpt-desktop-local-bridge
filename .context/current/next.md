# Next actions

Updated: 2026-10-02 16:20 MSK

1. Keep `ea074e0` as the immutable transport acceptance baseline.
2. Do not redesign submit/input again before locating the post-`ea074e0` regression.
3. Diff `ea074e0` against current transport-sensitive files, especially:
   - `MainWindow.xaml.cs`;
   - `Web/bridge-adapter.js`;
   - bootstrap/READY and conversation handling.
4. Separate later safety/durability changes from transport changes.
5. Integrate later M2/M3 behavior onto the proven baseline incrementally.
6. Use the exact unchanged `C:/Windows/win.ini` flow as the acceptance test at every transport-relevant step.
7. Require the same visible result as the Owner's screenshot: local read, `LOCAL_BRIDGE_RESULT_V1`, and final ChatGPT answer containing `[Mail]` / `MAPI=1`.
8. After current M3 code preserves that benchmark, run the durable-ledger live regression and close M3 on PASS.
9. Minimize external/GitHub checks in ordinary status replies; query only when fresh repository evidence is actually needed.
