# PC Gateway Client Entrypoint

Protocol: `pc-runner-gateway`
Client protocol version: `1.0.0`
Gateway: `lvlaksim1/pc-runner-gateway`
Transport: GitHub Issue queue

Rules:
1. This repository is a caller, not a runner owner.
2. PC execution goes only through `lvlaksim1/pc-runner-gateway`.
3. Do not send inline PowerShell in requests.
4. Executable project scripts belong under `.pc-gateway/tasks/`.
5. `repo.powershell` requests pin an exact 40-character commit SHA.
6. Task scripts accept `GatewayRequestPath` and `GatewayResultPath`.
7. Credentials never belong in request payloads or repository files.
