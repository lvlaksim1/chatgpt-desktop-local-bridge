# Manager beliefs

Manager generation: 26.
Updated: 2026-10-05 19:45 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d.
- Production Local Bridge transport remains unchanged.
- Private Transport v5 authenticated read-plane is live-proven.
- Autonomous PC Runner Gateway is now the default live-test path; Owner manual UI interaction is fallback-only.
- Pause/Resume with authoritative read-back are proven.
- Scheduled Task create/update/remove schedule contract is proven through current frontend-compatible /backend-api/automations/save serializer.
- Reversible arm/rearm composition on an existing bound paused task is proven autonomously: schedule update -> enable -> read-back/next-run -> disable -> new schedule -> enable -> read-back -> disable -> exact restoration.
- Reversible prompt mutation on an existing bound paused task is proven autonomously and restores the original prompt.
- Library data-plane lifecycle is proven autonomously: allocate file, signed-byte upload, terminal process_upload_stream completion, Library discovery, exact-byte download, rename/read-back, delete_stream completion.
- One-shot schedule format probing proved timing_mode must be integer 0/1/2; timing_mode=0 accepts Z, floating, and TZID=UTC DTSTART forms. String timing_mode values return 422.
- Creating a new automation bound by target_thread_id currently returns reproducible HTTP 503 with no read-back object; therefore dedicated-worker creation is not yet considered supported.
- The first Desktop -> Library request -> armed Scheduled runtime -> Library result E2E probe has been launched through runner request #240.
- Write reliability remains UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; never blind retry.
- No credentials/tokens/cookies are persisted.
