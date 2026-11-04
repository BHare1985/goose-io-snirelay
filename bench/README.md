# bench/: M6, tcprouter against the C proxy's epoll engine

Method: Steve's `proxybench.sh` (copied here unchanged from ~/dev/c_proxy, with backend.c, verify.py, verify_sni.py and proxy.c), suite
`tcp`, run as the user (no sudo, no perf, TUNE=0): `SUITE=tcp WORKERS=1 PIN=auto PERF=0 TUNE=0 TRICKS=0 VERIFY=1 SECS=8 ROUNDS=3 WARMUP=1`.
Rows: `direct` (the ceiling), `epoll_copy` (the C proxy, `--io epoll -m copy`: the like-for-like row, our engine copies), `epoll_hybrid`
(the C proxy with splice at large sizes: shows what splice buys), `goose` (tcprouter's `forward_server`, an optimised build).
`run_m6.sh` does it under the host lock; `memory.py` measures RSS idle, with 1,000 and 10,000 idle connections, and under load, for all three
proxies the same way (the bench itself does not report memory). Raw results, `uptime` and `docker ps` before and after, go under `results/`.

Rules: run only when the host is free (Danya's testbed and Demo 2 down: ask Charlie), nothing else running, same conditions for both
binaries, flag any run where wrk or the backend was the limit, and report losses plainly before tuning anything.
