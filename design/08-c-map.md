# 08 — Where the C proxy's parts go

The C proxy: `~/dev/c_proxy/proxy.c` (≈ 2,800 lines), `backend.c`, `gkproxy.h`. Its design rules
were chosen so this port is mechanical: one loop per core, share-nothing; flat records by index +
generation, never pointers; no malloc on the data path; dispatch on a tag in the event data, no
function pointers; liburing behind a thin C surface (`c_proxy/AGENTS.md`).

| C part | Goes to | v1? | Notes from Steve (2026-11-04) |
|---|---|---|---|
| Listener setup, `SO_REUSEPORT`, IPv4/6 | tcprouter | v1 | Add the port-in-use check (RT-1d) |
| ClientHello/SNI parser, fragmented records | tcprouter (doc 04) | v1 | Behaviour, not code |
| Routes, default, unknown/no-SNI | tcprouter | v1 | Routes are data |
| Connection pool, free stack, generations, packed user data | tcprouter | v1 | A `c_Slot[>..]` table + free list inside the `Worker` root (a root cannot hold a `slot_pool`) [V] |
| Copy forwarding, partial writes, half-close, EOF | tcprouter | v1 | |
| Backpressure (`spill`/`pump`), per-wakeup budget | tcprouter | v1 | Copy first |
| Pipe pool, splice, hybrid copy/splice switch | tcprouter | v2 | Splice later; leave the switch heuristics out |
| io_uring engine (COPY/SPLICE), provided buffers, ring-socket | — | no | epoll only (user): little gain measured |
| Smart ACKs, EOF probes, TFO (`-F`), bulk tuning | — | later | Measured optimisations, not correctness |
| Coarse timeout sweep | tcprouter | v1 | |
| Drain with deadline | tcprouter | v1 | |
| Per-worker stats | tcprouter | v1 | Gathered by message, not shared |
| Servers, targets, round robin, backups | tcpproxy | v1 of tcpproxy | |
| Passive failure + retry in `on_connect` | split: engine retries, policy decides | v1 | Coupled to "peek without consuming": RT-4c |
| `sessions` counter bumped by the engine | engine calls `connected`/`closed` on the policy | v1 | |
| Active health-check thread (TCP/HTTP) | — (Gatus decides, D43/D44) | no | Keep passive only |
| In-proxy DNS re-resolution | the program | no | Program resolves, sends addresses |
| Lease deadline check per loop pass, cut sessions | tcprouter primitive (deadlines, CloseTagged) + tcpproxy data | v1 | Top of every pass (RT-6) |
| Shared atomics in `servers[]` (up, maint, lease_until, versioned addr, sessions) | per-worker tables + broadcast messages | v1 | Absolute deadlines make late/duplicate messages harmless |
| Text control protocol (`show`, `down`, `lease` …) | the Gatekeeper proxy program | — | Same protocol so `verify_backends.py` runs unchanged |
| CLI flags, logging setup | the program | — | |
