# Current state

Updated: 2026-10-02 16:20 MSK

- manager generation: 14
- product authority: `main`
- current known product head: `6e2a0b54b727c5474bad40ac038f727a39cceb8d`
- canonical transport baseline: `ea074e06bd4e959106f49f57cad1ac731597dac3`
- Owner currently manually installed/tested the exact-morning benchmark application based on `ea074e0`
- BRIDGE-M1: CLOSED
- BRIDGE-M2: CLOSED
- BRIDGE-M3: ACTIVE
- durable foundation implementation: substantially complete
- canonical live benchmark: PASS on exact-morning `ea074e0`
- benchmark: `fs.read_text(C:/Windows/win.ini)`
- observed full round trip: request -> local read -> `LOCAL_BRIDGE_RESULT_V1` -> final ChatGPT answer
- application evidence: `fs.read_text completed in 2 ms.`
- visible answer included `[Mail]` and `MAPI=1`
- current diagnosis: transport regression was introduced after `ea074e0`
- restoring only current-code `form.requestSubmit()` was not sufficient
- next work: preserve full `ea074e0` transport behavior and layer later M2/M3 changes back incrementally
