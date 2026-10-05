# Manager beliefs

Manager generation: 25.
Updated: 2026-10-05 17:52 MSK

- Product authority remains main at 6e2a0b54b727c5474bad40ac038f727a39cceb8d; production Local Bridge transport is unchanged.
- Owner directive: live Windows/private-transport testing should be performed autonomously through PC Runner Gateway whenever technically possible. Manual Owner clicks/screenshots are fallback-only.
- PC Runner Gateway is lvlaksim1/pc-runner-gateway with trusted Windows runner pc-gateway-primary. chatgpt-desktop-local-bridge is already allowlisted for repo.powershell under .pc-gateway/tasks/.
- Gateway health/inventory request #204 completed SUCCESS.
- Private Transport v5 read-plane remains live-proven: scheduled=200, paused=200, library=200, storage=200.
- Manual Pause contract remains proven: POST /backend-api/automations/set_status with jawbone_id and is_enabled=false, HTTP 201 plus read-back.
- Runner-driven control-plane cycle request #208 / run 37326704107 completed SUCCESS. The bounded probe itself requires pause HTTP 201/read-back false, resume HTTP 201/read-back true, and restoration of the original enabled state. Therefore Resume is now independently live-proven by the runner.
- Runner test scripts must be bounded and must not leave a long-lived GUI descendant under gateway PowerShell because Repo-PowerShell waits the descendant process tree.
- Ordinary app restoration is implemented as a separate runner task using Windows Task Scheduler InteractiveToken. Restore request #210 / run 37328012071 completed SUCCESS.
- Current runner automation branch: exp/runner-private-transport-control-plane, draft PR #30, head f6bbfa6611b5cb2e33b57739e191ccdce15aac7e.
- Next research stages should be runner-driven: task schedule mutation, one-shot arm/rearm, then Library/file write lifecycle.
- Writes retain UNKNOWN_OUTCOME -> authoritative read-back -> reconcile; no blind retry.
