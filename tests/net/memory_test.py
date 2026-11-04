#!/usr/bin/env python3
# Proves: RT-5a RT-5b   (an idle forwarded connection holds no pool buffer; and costs at most 512 bytes)
#
#     tests/net/memory_test.py
#
# RT-5a: 1,000 idle connections hold no buffer; a byte in flight borrows one and gives it back.
# RT-5b: RSS growth over 10,000 idle connections, divided by 10,000, is at most 512 bytes. That needs about
#        40,000 file descriptors across the driver, the backend and the proxy. The test raises its soft limit to the
#        hard limit first (524288 on this host). If that is still too low the test FAILS with the numbers: a skip is
#        not a pass, the row is done only when it has run.
# RT-5a also cross-checks the buffers_in_use stat against memory: RSS growth over the 1,000 idle connections must stay
#        under 1,000 x buffer_size / 4, so a stat that lies shows up as memory.
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("memory_test", "RT-5a RT-5b")
host_lock()

def open_idle(port, n):
    conns = []
    for _ in range(n):
        conns.append(connect(port, timeout=10))
    return conns

def rt5a():
    raise_nofile(8192)
    buffer_size = 32768
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=4096)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, nofile=8192, stat_ms=200)
    try:
        server.start().wait_ready()
        time.sleep(0.5)
        rss_before = server.rss_kb()
        conns = open_idle(pport, 1000)
        opened = server.wait_stat("open", lambda v: v == 1000, timeout=5)
        time.sleep(2)
        t.check(server.total("open") == 1000, f"RT-5a 1,000 idle connections are open in the worker (saw {server.total('open')})")
        t.check(server.total("buffers_in_use") == 0, f"RT-5a idle connections hold no buffer (buffers_in_use={server.total('buffers_in_use')})")
        # The stat has to be honest (Charlie): if the worker really held a buffer per idle connection, RSS would
        # grow by 1,000 x buffer_size = 32 MB; the ceiling is a quarter of that.
        grown = (server.rss_kb() - rss_before) * 1024
        ceiling = 1000 * buffer_size // 4
        t.note(f"RT-5a measured: RSS grew {grown / 1024:.0f} kB over 1,000 idle connections (ceiling {ceiling // 1024} kB)")
        t.check(grown < ceiling, f"RT-5a RSS growth over 1,000 idle connections stays under 1,000 x buffer_size / 4 ({grown} < {ceiling} bytes)")
        t.check(backend.open_count() == 1000, f"RT-5a each idle client has its backend connection ({backend.open_count()})")

        # One byte on every 10th connection and back: a buffer is borrowed only while the byte is in flight.
        for i in range(0, 1000, 10):
            conns[i].sendall(bytes([i % 256]))
        for i in range(0, 1000, 10):
            got = recv_exact(conns[i], 1)
            if got != bytes([i % 256]):
                t.check(False, f"RT-5a the byte on connection {i} came back wrong")
                break
        time.sleep(1)
        t.check(server.total("buffers_in_use") == 0, f"RT-5a after the bytes came back, buffers_in_use is 0 again ({server.total('buffers_in_use')})")
        t.check(server.max_buffers_in_use <= 100, f"RT-5a at most one buffer per active connection was ever in use (max {server.max_buffers_in_use})")

        for c in conns: c.close()
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=5) == 0, "RT-5a closing every client closes every connection")
        t.check(server.alive() and not server.stderr, f"RT-5a the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

def rt5b():
    N = 10_000
    need = 4 * N + 200
    got = raise_nofile(1 << 30)            # as high as the hard limit allows
    if got < need:
        # A SKIP is not a pass: the row stays unproven, the run says why, and the test fails so nobody misses it.
        t.check(False, f"RT-5b cannot run here: it needs RLIMIT_NOFILE {need} and the hard limit is {got} "
                       f"(take it to the user: raise `ulimit -Hn`)")
        return
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=16384)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, nofile=got, stat_ms=200)
    try:
        server.start().wait_ready()
        # Warm up: one connection with traffic, so first-use costs (tables, buffer pages) are in the baseline.
        c = connect(pport); c.sendall(b"warm"); recv_exact(c, 4); c.close()
        server.wait_stat("open", lambda v: v == 0, timeout=3)
        time.sleep(1)
        base = server.rss_kb()
        conns = open_idle(pport, N)
        server.wait_stat("open", lambda v: v == N, timeout=15)
        time.sleep(1)
        after = server.rss_kb()
        per = (after - base) * 1024 / N
        t.note(f"RT-5b measured: RSS {base} kB -> {after} kB over {N} idle connections = {per:.0f} bytes each (limit 512)")
        t.check(server.total("open") == N, f"RT-5b {N} idle connections are open (saw {server.total('open')})")
        t.check(per <= 512, f"RT-5b memory per idle connection is at most 512 bytes (measured {per:.0f})")
        for c in conns: c.close()
    finally:
        server.stop(); backend.stop()

t.run(rt5a)
t.run(rt5b)
t.finish()
