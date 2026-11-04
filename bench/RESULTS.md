# M6 results (2026-11-04, tcprouter commit in results/*/tcprouter-commit.txt)

Host: AMD Ryzen 5 3550H (4 cores / 8 threads), run as the user (no sudo, no perf, TUNE=0), Danya's testbed and Demo 2 stopped, 1-minute load
under 0.5 at the start, host lock taken, `SUITE=tcp WORKERS=1 PIN=auto` (proxy on cpu 0, backend on 2,3, wrk on 4-7), 8 s x 3 rounds, medians.
`proxybench.sh` is Steve's, with ONE local change (`NOROOT=1` skips its root check; line 89). Correctness (verify.py): direct, epoll_copy, epoll_hybrid
and goose all PASS. Raw data: `results/20261104-202822/` (report.txt, results.json, logs, sysinfo, uptime and docker ps before and after).
Goose = tcprouter's forward_server, optimised build, copy-only (no splice). Like-for-like row: epoll_copy. epoll_hybrid shows what splice buys.

## Throughput and p99 (req/s; goose as a percentage of epoll_copy)

| workload | direct | epoll_copy | epoll_hybrid | goose | goose / copy | p99 copy / goose |
|---|---:|---:|---:|---:|---:|---:|
| 11 B, 64 conns | 180,231 | 57,570 | 57,337 | 56,920 | 98.9% | 2.89 / 2.05 ms |
| 11 B, 512 conns | 143,574 | 45,840 | 45,795 | 44,549 | 97.2% | 15.49 / 15.74 ms |
| 11 B, new connection per request | 46,670 | 10,553 | 10,485 | 8,538 | **80.9%** | 8.82 / 15.29 ms |
| 16 KiB, 64 conns | 130,091 | 43,011 | 46,472 | 27,301 | **63.5%** | 2.14 / 3.99 ms |
| 64 KiB, 64 conns | 58,539 | 16,346 | 27,544 | 11,350 | **69.4%** | 5.01 / 9.43 ms |
| 1 MiB, 16 conns | 4,905 | 1,362 | 5,039 | 890 | **65.3%** | 15.52 / 24.17 ms |
| web mix, 64 conns | 99,971 | 30,759 | 40,273 | 25,017 | **81.3%** | 3.74 / 13.69 ms |

## Proxy CPU per request (core microseconds, all proxy cores busy 100% in every row: the proxy is the limit)

| workload | epoll_copy | goose |
|---|---:|---:|
| 11 B, 64 | 17.3 | 17.5 |
| 11 B, 512 | 21.7 | 22.4 |
| new connection | 94.5 | 116.8 |
| 16 KiB | 23.2 | 36.5 |
| 64 KiB | 61.1 | 88.0 |
| 1 MiB | 729.9 | 1,121.1 |
| web mix | 32.4 | 39.8 |

## Memory (bench/memory.py, same sampler for all three; VmRSS from /proc/PID/status, one proxy thread)

| | idle RSS | with 1,000 idle conns | with 10,000 idle conns | per idle connection (1,000 / 10,000) | peak under wrk load (64 conns, 16 KiB) |
|---|---:|---:|---:|---:|---:|
| C epoll_copy | 2,616 kB | 2,788 kB | 4,372 kB | 176 / 180 bytes | 4,392 kB |
| C epoll_hybrid | 2,624 kB | 2,796 kB | 4,380 kB | 176 / 180 bytes | 4,400 kB |
| goose | 4,340 kB | 4,504 kB | 5,768 kB | **168 / 146 bytes** | 5,804 kB |

## Reading, plainly

- **Goose ties the C epoll_copy proxy on small messages** (98.9% and 97.2% of its throughput, same CPU per request, p99 better at 64 connections) and **uses
  slightly less memory per idle connection** (146-168 bytes vs 176-180), but **a larger base** (4.3 MB idle vs 2.6 MB: the runtime and data stacks, not connections).
- **Goose LOSES on throughput wherever more than a few KB per request move**: 63-69% of the like-for-like C row at 16 KiB, 64 KiB and 1 MiB, 81% on the web mix, and
  81% with a new connection per request. CPU per request is 1.4-1.6x the C copy row at 16 KiB-1 MiB. Against epoll_hybrid at 1 MiB (splice, 0 copies) it is 18% (890 vs 5,039).
  p99 latency is worse in the same rows (about 1.5-2.5x).
- **Limits of the measurement**: `direct` is backend-bound (100%) and client-bound in the new-connection row, so it is only a ceiling and says nothing about the proxies.
  In every proxy row the proxy cores were 100% busy, wrk 20-55% and the backend 19-55%, so the proxies, not the load generators, were the limit. 1 MiB: epoll_hybrid itself
  was backend-bound (99%), so its number is a floor for it. No perf counters (no root), so there is no instruction-level profile.
- **Not profiled, not tuned** (as asked). Candidate causes I have NOT verified: our buffer is 16 KiB (`limits.buffer_size`) so a 1 MiB response takes 64+ read/write
  round trips per direction against fewer with a larger buffer; one `recv` per epoll event and level-triggered re-arming per chunk; `epoll_ctl(MOD)` after every state change
  (`_update_epoll_interest`); the per-request cost of connection setup (slot, route match, parse address, connect) for the new-connection row.
  The first thing I would measure, with Steve's `PROFILE=` or `strace -c`, is syscalls and epoll_ctl calls per request.

## Performance pass 1 (buffer size, drain loop, setup syscalls)

Method: `bench/syscalls.py` (strace -c -f, 4 s of wrk) for counts; `bench/run_m6.sh QUICK` for throughput (3 rounds, same host, same method as above).

| change | what the counts showed |
|---|---|
| `Limits.buffer_size` 16 KiB -> 32 KiB (the C proxy's `bufsz`) | 16 KiB response: 6.2 -> 4.2 syscalls/request (C: 4.2). 1 MiB: 142 -> 87 (C: 69.5) |
| read -> write loop until a short read, at most 64 KB per wakeup (`_WAKEUP_BUDGET`) | 1 MiB: epoll_wait 4.4 -> 1.4 per request (C: 0.2); total 87 -> 83 |
| TCP_NODELAY set once on the listener (accepted sockets inherit it); no `shutdown` when both directions have ended and the close follows | new connection: 21.5 -> 19.5 syscalls (C: 15.4) |

Delayed client registration (client joins epoll when the connect finishes, 4th change): new connection 19.5 -> 18.5 syscalls (C: 15.4). All 21 test files unchanged.

### Before and after, same method (bench/run_m6.sh, full: 8 s, 3 rounds, 1 worker, medians of 3; after = bench/results/20261104-212103)

| row | goose before | goose after | epoll_copy | before | after |
|---|---|---|---|---|---|
| 11 B keep-alive | see run 20261104-202822 | 49,865 | 51,336 | | 97.1% |
| 11 B new connection per request | | 8,805 | 10,533 | 81% | 83.6% |
| 16 KiB | | 42,269 | 42,576 | 63.5% | 99.3% |
| 64 KiB | | 16,589 | 16,273 | 63-69% | 101.9% |
| 1 MiB | | 1,347 | 1,424 | 63-69% | 94.6% |
| web mix | | 30,355 | 30,862 | 81% | 98.4% |

NOT parity on two rows: 1 MiB (94.6%) and new connection per request (83.6%). Run-to-run noise on this host is about +-3%.

New connection per request: both proxies spend ~4.8 of 5 CPU seconds in the kernel (user 0.15 s vs 0.12 s), so the gap is syscalls: 18.5 vs 15.4 per request.
Earlier I attributed the difference to half-close semantics. That was wrong: the C proxy passes the same half-close scenarios as RT-4b (client half-close with a 2 MB reply, backend half-close then 2 MB back; both `epoll_copy` and `-v`, checked 2026-11-04 with a standalone script), so half-close is not what costs the syscalls.
The real difference is the engine design: the C proxy registers each socket once with `EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET` and tracks readiness in flags, so it makes 2 `epoll_ctl` per connection and none on the data path. Ours is level-triggered and changes interest (4 `epoll_ctl`: ADD, ADD, MOD to start reading the server, MOD to stop at EOF) and does one more `recv` (EOF of the second side). Closing that gap means moving to edge-triggered readiness, a redesign of backpressure (RT-5c/5d), not a tuning change.

## Idle RSS breakdown (measured 2026-11-04, one idle worker, no connections)

| | RSS | anonymous |
|---|---|---|
| C epoll_copy | 2,620 kB | 480 kB |
| forward_server (Goose) | 4,328 kB | 2,292 kB |
| same, with `Config.routes` capped at 16 instead of 256 (experiment, not committed) | 2,480 kB | 444 kB |
| empty Goose program / root struct with 1 or 3 growable fields | 2,068 kB / same / same | 104 kB |

The +1.7 MB is not the Goose runtime and not the data stacks: a growable field reserves a 2 MB region of virtual memory that costs no resident memory until used (empty program: 2,068 kB, unchanged by adding fields). It is `Config`: 256 routes of about 800 bytes (the inline SNI match plus a Target of 8 addresses of 64 bytes) is about 200 kB, and a `Config` passed by value is copied and touched in full each time. The process holds about nine copies (main's, `spawn`'s argument, the thread's, `Worker.cfg`, `start`'s argument, ...): nine 2 MB regions with ~200 kB resident each, 1.8 MB together. Shrinking the cap to 16 routes removes all nine and brings idle RSS to 2,480 kB, below the C proxy. Not fixed yet: options are fewer copies (`const Config&`) or a smaller `Route`.

Config passed as `const Config&` to `spawn`, `start` and `_probe_listeners` (was by value): idle RSS 4,328 -> 3,936 kB (C: 2,620). Micro-benchmarks of the same shape (256 x 800-byte routes, 205 kB): constructing a `Config` costs about 600 kB resident wherever it happens (a literal is built and copied twice), a copy by assignment or into a thread costs about 210 kB, a by-reference argument costs nothing. The process still constructs two (main's, and `Worker.cfg`'s default) and copies two (`w.cfg = cfg`, the thread's argument): about 1.7 MB. Getting to C's number needs a smaller `Route` (Match name 253 B inline + Target of 8 x 64 B addresses inline), not fewer copies.

Route shrink (approved API change): `Addr.text` 64 -> 48 bytes; targets moved out of the routes into `Config.targets: Target[..64]`, `Action.Forward { to: u16 }` holds an index (`add_target(cfg, t)` returns it; check() reports an index not in the table). `Config` went from about 205 kB to about 95 kB. Idle RSS: 3,936 -> 3,024 kB (anonymous 984 kB; C: 2,620 / 480). The target was <= 2,880 kB (10% over C): NOT met, 144 kB over. Building `Worker.cfg` without a default (to skip the second construction) compiles but changes nothing measurable, so it is not done. What is left is the two constructions and two copies of a 95 kB Config (about 600 kB), plus a Goose process base of about 100 kB anonymous.
