#!/usr/bin/env python3
# Proves: RT-10a RT-10b   (a posted message reaches every worker once; gather_stats sums every worker's counters exactly)
#
#     tests/net/message_test.py
#
# forward_server --control with 4 workers; `stats` on its control thread calls tcprouter::gather_stats(4), which posts a Stats
# message and adds up the four replies, and prints one TOTAL line. The numbers are compared with what this test itself did.
import os, socket, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("message_test", "RT-10a RT-10b")
host_lock()
WORKERS = 4

def rig():
    echo_port = free_port()
    echo = EchoBackend(echo_port, backlog=1024)
    refused = free_port()
    ports = {k: free_port() for k in ("plain", "t7", "t8", "dead", "idle")}
    routes = [("plain", f"127.0.0.1:{echo_port}", None), ("t7", f"127.0.0.1:{echo_port}", (7, 1)), ("t8", f"127.0.0.1:{echo_port}", (8, 1)),
              ("dead", f"127.0.0.1:{refused}", None), ("idle", f"127.0.0.1:{echo_port}", None)]
    extra = ["--control", "--idle-timeout-ms", "1000"]
    for name, target, tag in routes:
        if tag:
            extra += ["--tagged-route", f"127.0.0.1:{ports[name]}={target}@{tag[0]}:{tag[1]}"]
        else:
            extra += ["--route", f"127.0.0.1:{ports[name]}={target}"]
    server = Server([], [], workers=WORKERS, stat_ms=500, nofile=8192, extra=extra)
    return echo, server, ports

def rt10a():
    echo, server, ports = rig()
    try:
        server.start().wait_ready()
        # Work spread over the workers, then the same totals 50 times: a lost reply would hang gather_stats, a duplicate would
        # leave a stray reply that corrupts the next call (a sum that changes).
        for i in range(40):
            c = connect(ports["plain"]); c.sendall(b"x"); recv_exact(c, 1); c.close()
        first = server.totals()
        t.check(first["accepted"] == 40, f"RT-10a gather_stats sees the 40 connections the 4 workers accepted ({first['accepted']})")
        same = 0
        for i in range(50):
            d = server.totals(timeout=3)
            same += 1 if d["accepted"] == 40 and d["bytes_in"] == first["bytes_in"] else 0
        t.check(same == 50, f"RT-10a 50 Stats messages in a row each reached every worker exactly once: the sum never changes ({same}/50)")
        t.check(server.alive() and not server.stderr, f"RT-10a the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); echo.stop()

def rt10b():
    echo, server, ports = rig()
    try:
        server.start().wait_ready()
        up = 5000
        # 300 plain connections: each sends `up` bytes and gets them echoed
        def plain(n):
            for _ in range(n):
                c = connect(ports["plain"], timeout=10)
                c.sendall(os.urandom(up)); recv_exact(c, up); c.close()
        run_threads([lambda: plain(50) for _ in range(6)])
        # 40 connections under tag 7 and 20 under tag 8, kept open while the totals are read
        t7 = [connect(ports["t7"]) for _ in range(40)]
        t8 = [connect(ports["t8"]) for _ in range(20)]
        for c in t7 + t8:
            c.sendall(b"hello"); recv_exact(c, 5)
        # 20 connections to a target that refuses
        for _ in range(20):
            c = connect(ports["dead"], timeout=5)
            c.settimeout(3)
            try: c.recv(10)
            except OSError: pass
            c.close()
        # 10 connections that say nothing and are closed by the 1 s idle timeout
        idle = [connect(ports["idle"]) for _ in range(10)]
        for _ in range(4):                                  # keep the 60 held connections busy while the idle ones time out
            time.sleep(0.4)
            for c in t7 + t8:
                c.sendall(b"k"); recv_exact(c, 1)
        expect_extra = 60 * 4
        d = server.totals()
        expect_bytes_in = 300 * up + 60 * 5 + expect_extra
        t.check(d["accepted"] == 300 + 60 + 20 + 10, f"RT-10b accepted adds up across 4 workers: 390 (saw {d['accepted']})")
        t.check(d["open"] == 60, f"RT-10b open connections: 60 (saw {d['open']})")
        t.check(d["bytes_in"] == expect_bytes_in and d["bytes_out"] == expect_bytes_in, f"RT-10b bytes in and out: {expect_bytes_in} each (saw {d['bytes_in']} and {d['bytes_out']})")
        t.check(d["connect_failures"] == 20 and d["retries"] == 0, f"RT-10b connect failures 20 and retries 0 (saw {d['connect_failures']} and {d['retries']})")
        reasons = dict(zip(Server.CLOSE_REASONS, d["closed"]))
        t.check(reasons["IdleTimeout"] == 10, f"RT-10b closed by IdleTimeout: 10 (saw {reasons['IdleTimeout']})")
        t.check(reasons["ConnectFailed"] == 20, f"RT-10b closed by ConnectFailed: 20 (saw {reasons['ConnectFailed']})")
        t.check(reasons["PeerClosed"] + reasons["PeerReset"] == 300, f"RT-10b closed by the peers: 300 (saw {reasons['PeerClosed'] + reasons['PeerReset']})")
        t.check(d["tags"] == {7: 40, 8: 20}, f"RT-10b sessions per tag: {{7: 40, 8: 20}} (saw {d['tags']})")
        for c in t7 + t8 + idle: c.close()
        time.sleep(0.5)
        d2 = server.totals()
        t.check(d2["open"] == 0 and d2["tags"] == {}, f"RT-10b after everything closes: open 0 and no tag sessions (saw {d2['open']}, {d2['tags']})")
        t.check(server.alive() and not server.stderr, f"RT-10b the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); echo.stop()

t.run(rt10a)
t.run(rt10b)
t.finish()
