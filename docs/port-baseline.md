# Baseline before the port onto goose-io (2026-11-22)

Tree: HEAD 8cd67fe (own engine). Compiler: goose v2026.4. `GOOSE=goose tests/run_tests.sh`, one run, nothing else on the host:
**46 test files run, 0 failed.** Speed and memory baselines (`bench/run_m6.sh`, `bench/memory.py`) are measured back to back with the port at acceptance.

## Speed at acceptance (2026-11-23)
Old engine (8f1d8e4) vs the port, `proxybench.sh` tcp suite, 1 worker, medians of 3 rounds, back to back: 11 B c=64 100.6%, 11 B c=512 97.5%,
16 KiB 99.5%, 64 KiB 101.4%, 1 MiB 97.3%, web mix 99.8% (all at least 95%). Fix that got there: the ext relay pump no longer issues a recv that would
only say EAGAIN after a short read. New-connection-per-request row not measured. Memory: 746 bytes per idle connection (RT-5b bound 1024, design D9).

New connection per request (wrk `Connection: close`, 64 conns, one worker, medians of 6): old engine 8,366 req/s, port 7,396 (88%), C epoll copy 8,791.
Remaining cost per request vs old: two getpeername (peer remembered for peer_address in Closed), one getsockname (relay self-connection check),
four extra epoll_ctl (connect registers for OUT then switches to IN; end of stream switches IN off), one extra shutdown. Below the 95% bar; keep-alive workloads are all at least 97%.
Memory (bench/memory.py method, 1 worker): idle connection 174 B (old engine), 703 B (port), 184 B (C epoll copy); 10,000 idle: 4.7 MB, 10.4 MB, 4.4 MB.
