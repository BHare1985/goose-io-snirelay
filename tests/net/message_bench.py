#!/usr/bin/env python3
# The message benchmark Charlie asked for: what widening Message from 16 to 64 bytes costs.
#
#     FORWARD_SERVER=path/to/forward_server python3 message_bench.py [rounds]
#
# `stats` on forward_server's control thread posts Message.Stats to every worker and waits for every reply (gather_stats), so one call is
# one pipe write per worker plus one reply per worker: the path every state, deadline and address message takes. The numbers are
# gathers per second and the median and p99 latency of one gather, with 4 workers and 1 worker, in the order they are measured. Run it
# before the change (baseline) and after, on an idle host (tests use host_lock), and report both. The cost is the difference.
# It also posts `deadline` messages back to back, which do not wait for a reply, and reports how long the control thread needed to write them
# all (pipe write cost alone).
import os, statistics, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
host_lock()
N = 2000

def gather(server, timeout=5):
    """Like Server.totals(), but polls the TOTAL line every 100 us (netlib sleeps 20 ms, which would hide the pipe cost entirely)."""
    with server._lock:
        seen = sum(1 for l in server.lines if l.startswith("TOTAL "))
    server.command("stats")
    end = time.perf_counter() + timeout
    while time.perf_counter() < end:
        with server._lock:
            n = sum(1 for l in server.lines if l.startswith("TOTAL "))
        if n > seen: return
        time.sleep(0.0001)
    raise TimeoutError("no TOTAL line")

def one(workers):
    server = Server([], [], workers=workers, stat_ms=60000, extra=["--control", "--route", f"127.0.0.1:{free_port()}=127.0.0.1:1"])
    try:
        server.start().wait_ready()
        for _ in range(100): gather(server)                                   # warm up
        lat = []
        t0 = time.perf_counter()
        for _ in range(N):
            a = time.perf_counter()
            gather(server)
            lat.append(time.perf_counter() - a)
        wall = time.perf_counter() - t0
        lat.sort()
        t1 = time.perf_counter()
        for i in range(100000): server.command(f"deadline 7 {i + 1}")           # fire and forget: the control thread's write cost
        gather(server)                                                          # all of them were read by the control thread before this returns
        post = time.perf_counter() - t1
        return N / wall, lat[N // 2] * 1e6, lat[int(N * 0.99)] * 1e6, post
    finally:
        server.stop()

for workers in (4, 1):
    rows = [one(workers) for _ in range(rounds)]
    med = lambda k: statistics.median(r[k] for r in rows)
    print(f"workers={workers}: {med(0):8.0f} gathers/s   median {med(1):7.0f} us   p99 {med(2):7.0f} us   100000 posts + 1 gather {med(3)*1000:7.0f} ms   (median of {rounds} rounds of {N})")
