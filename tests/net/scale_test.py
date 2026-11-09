#!/usr/bin/env python3
# Proves: RT-2a   (10,000 concurrent idle connections are held by ONE worker, and are all still usable)
#
#     tests/net/scale_test.py
#
# Opens 10,000 connections through a single-worker forward_server (so 10,000 on the client side, 10,000 on the proxy's
# backend side, 20,000 in the proxy), waits until the proxy counts them all open, sends a request on 200 of them spread
# across the set and checks the replies, then closes everything and checks the count returns to zero. Needs about 40,000
# descriptors in the test process; if the hard limit is lower the test FAILS and says so (a skip is not a pass).
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("scale_test", "RT-2a")
host_lock()

def rt2a():
    N = 10_000
    need = 4 * N + 200
    got = raise_nofile(1 << 30)
    if got < need:
        t.check(False, f"RT-2a cannot run here: it needs RLIMIT_NOFILE {need} and the hard limit is {got} (raise it: ulimit -Hn)")
        return
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=16384)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, nofile=2 * N + 1000, stat_ms=200)
    conns = []
    try:
        server.start().wait_ready()
        base = server.rss_kb()
        for i in range(N):
            conns.append(connect(pport, timeout=30))
        opened = server.wait_stat("open", lambda v: v == N, timeout=30)
        t.check(opened == N, f"RT-2a the worker holds {N} open connections (counted {opened})")
        time.sleep(1.0)
        t.check(server.total("open") == N and server.total("buffers_in_use") == 0,
                f"RT-2a ... still {server.total('open')} open and {server.total('buffers_in_use')} buffers in use after a second idle")
        bad = 0
        for i in range(0, N, N // 200):
            c = conns[i]
            c.settimeout(10)
            msg = b"ping-%d" % i
            c.sendall(msg)
            try:
                if recv_exact(c, len(msg)) != msg:
                    bad += 1
            except (OSError, EOFError):
                bad += 1
        t.check(bad == 0, f"RT-2a 200 of the 10,000, spread across the set, each answer a request correctly ({bad} bad)")
        t.note(f"RT-2a measured: RSS {base} kB idle, {server.rss_kb()} kB with {N} connections open = {(server.rss_kb() - base) * 1024 // N} bytes per connection")
        for c in conns: c.close()
        conns = []
        closed = server.wait_stat("open", lambda v: v == 0, timeout=30)
        t.check(closed == 0, f"RT-2a closing them all returns the count to zero ({closed})")
        t.check(server.alive() and not server.stderr, f"RT-2a the worker is up and silent ({server.stderr[:2]})")
    finally:
        for c in conns:
            try: c.close()
            except OSError: pass
        server.stop(); backend.stop()

t.run(rt2a)
t.finish()
