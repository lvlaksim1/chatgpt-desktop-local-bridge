# Next actions

Updated: 2026-10-03 05:49 MSK

1. Treat `0.2.8.0` / `af6ac653` on `dev/ui-shell-v5` as the accepted UI recovery baseline.
2. Make the next UI change narrowly scoped: address loading/black-area behavior using ordinary `WebView2` only, preserving bridge restore and background preloading.
3. Build a development prerelease, require Windows CI success, then obtain Owner-side runtime validation before accepting that commit as the next baseline.
4. Only after that validation, separately address loaded-tab switch flash.
5. Then separately restore/verify native download behavior for ordinary clicks.
6. Reintroduce the explicit custom “Открыть в новой вкладке” action using safe DOM/adapter-cached target resolution; never use direct `ContextMenuTarget.LinkUri`.
7. Harden optional UI event handlers so their failures cannot crash the whole process.
8. Expand unified theme coverage, add explicit theme reset, and keep full Setup under Settings → Updates while the ordinary top update path remains delta-focused.
9. After UI recovery, implement Diagnostics filters/copy/expand/export and distinguish tool-execution success from delivery failure.
10. Continue transport research, fine-grained ASK permissions, tool expansion, and production hardening after the UI/transport foundations are stable.
11. Use Local Bridge + local `git`/`gh` as the default GitHub execution channel whenever available; batch bounded dependent work where safe.
12. Reconcile the M4 process/write lineage with product authority `main` while preserving the exact `ea074e0` transport behavior and later M3 durability.
13. Reproduce and harden staged-but-not-auto-submitted result delivery.
14. Add Windows Job Object or equivalent robust bridge-owned process containment before broad shell/process expansion.
15. Keep release retention clean and persist future significant state changes to `manager-state` as sealed generations.
