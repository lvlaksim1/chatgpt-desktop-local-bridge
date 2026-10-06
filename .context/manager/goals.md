# Manager goals

Manager generation: 32.
Updated: 2026-10-06 07:14 MSK

1. Deliver a reliable signed-in ChatGPT Windows client with policy-controlled native computer access.
2. Preserve current Local Bridge as production fallback while the server-side transport remains experimental.
3. Build the alternative transport only from live-proven narrow Scheduled Tasks and authenticated in-product backend primitives.
4. Enforce the Owner safety invariant globally: no parallel/burst network traffic and at least 5 seconds between explicit network/API/backend requests.
5. Keep authorization material inside the authenticated WebView page context.
6. Make all write operations crash-safe and read-back-reconciled.
7. Prove a complete no-composer/no-DOM-input Desktop -> Scheduled runtime -> Desktop round trip.
8. Test whether the request can be carried directly in the Scheduled Task prompt and the response carried by latest_backing_run, avoiding the unproven worker-side Library surface.
9. Add READY/ACK and correlation fencing after the first complete request->worker->result cycle is proven.
10. Run restart, duplicate, stale-ACK, relogin/navigation, forced network-loss, orphan-cleanup and 100+ round-trip endurance before any production promotion.
