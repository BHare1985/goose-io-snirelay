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
