# Manager goals

Manager generation: 33.
Updated: 2026-10-06 07:35 MSK

1. Deliver a reliable signed-in ChatGPT Windows client with policy-controlled native computer access.
2. Preserve current Local Bridge as production fallback while server-side transport remains experimental.
3. Build the alternative transport only from live-proven Scheduled Tasks and authenticated in-product backend primitives.
4. Enforce serialized >=5 second network/API/backend pacing.
5. Keep authorization material inside the authenticated WebView page context.
6. Make all writes crash-safe and read-back-reconciled.
7. Promote the now-proven prompt -> Scheduled runtime -> latest_backing_run primitive into a minimal framed transport.
8. Add generation/seq/message_id fencing, duplicate suppression and stale-response rejection.
9. Remove incidental Library operations from the prompt-transport critical path.
10. Run restart, duplicate, stale-ACK, relogin/navigation, network-loss, orphan-cleanup and 100+ round-trip endurance before any production promotion.
