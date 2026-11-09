# What allocates, and when (RT-11c)

Everything here is measured on this host (AMD Ryzen 5 3550H, Linux, `goose 751794c`) unless it says "design". The numbers come
from `bench/memory.py`, `tests/net/scale_test.py` (RT-2a) and `tests/net/flat_memory_test.py` (RT-5g); `bench/RESULTS.md` has the history.

Goose has no heap: every byte below lives in a variable, a `slot_pool`, a growable array, or a C-side buffer. Nothing is allocated
per request except what is named here.

## At start

| What | Size | When | Notes |
|---|---|---|---|
| `Config` | about 95 kB (listeners 16, routes 256, targets 64) | built by you; the process holds a few copies | `check(cfg)` first. A growable field reserves virtual memory (2 MB) that costs nothing until used. |
| One `Worker` per core | empty growable tables for connection slots and pool buffers | `Worker.start` | Slots are created as connections arrive and reused through a free list (up to `max_conns_per_worker`, default 65,536); generation counters make a stale `Conn` harmless. |
| Idle process | **3,024 kB RSS** with one worker (C epoll proxy: 2,620 kB) | measured | 404 kB over the C proxy. A shared name pool saved 436 kB and was reverted for readability (RESULTS.md). |

## Per connection

| What | Size | Notes |
|---|---|---|
| Slot | about 150 to 170 bytes of resident memory per idle connection | measured: 169 bytes (RT-2a, 10,000 idle connections through one worker: 4,440 to 6,100 kB); C proxy 176 to 180 |
| I/O buffers | none while idle | the pool is lazy: a buffer is taken on the first read that has data and given back when it is drained |
| Forwarding | up to two 32 KiB buffers (one per direction) while bytes are in flight | `Limits.buffer_size` and `buffers_per_worker` (default 4,096, so at most 128 MiB per worker); when the pool is empty reads wait, nothing is allocated |
| Handler mode `send` queue | at most 4 pool buffers (128 KiB) per connection | `send` is all or nothing; after a `false` you get one `Writable` |
| Handler `Data` event | one pool buffer until your block returns | |

## Under load: it stays flat (RT-5g)

`flat_memory_test` forwards 21.5 GB (both directions) through one worker: RSS 4,900 to 5,156 kB, high-water the same, pool 5 to 13
buffers. Growth stops at the pool's working set; it does not follow the byte count.

Peak under wrk load (64 connections, 16 KiB): C 4,392 kB, Goose 5,804 kB (first M6 set, before the edge-triggered pass).

## What can still grow

* The pending-event queue of handler mode (flat records) grows with the events one pass produces, then is cleared.
* Your own state (the `slot_pool` in `examples/http_server.goose` is 4 KiB inbox + 512 B head per session, plus the file table).
* The tag table (deadlines set by message) holds at most 16 tags per worker, a fixed array; it does not grow.
* The side table of targets given to `forward()` grows with the number of distinct targets in use at once; unused entries are reused.

Unverified: behaviour when `buffers_per_worker` is exhausted for long (reads wait; covered by `backpressure_test`, not measured for RSS).
