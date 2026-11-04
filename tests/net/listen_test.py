#!/usr/bin/env python3
# Proves: RT-1a   (A worker listens on every configured IPv4 and IPv6 address and accepts connections)
#
#     tests/net/listen_test.py        (run_tests.sh builds harness/forward_server and sets FORWARD_SERVER)
#
# One worker, a listener on 127.0.0.1 and one on [::1], both forwarding to an echo backend.
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("listen_test", "RT-1a")
host_lock()

def body():
    backend_port = free_port()
    backend = EchoBackend(backend_port)
    v6 = has_ipv6()
    p4 = free_port()
    p6 = free_port("::1") if v6 else None
    listens = [f"127.0.0.1:{p4}"] + ([f"[::1]:{p6}"] if v6 else [])
    if not v6:
        t.skip("RT-1a IPv6 listener", "this host has no IPv6 loopback")
    server = Server(listens, [f"127.0.0.1:{backend_port}"], workers=1)
    try:
        server.start().wait_ready()
        t.check(server.alive(), "RT-1a the worker is running after start()")

        def ping(port, host, payload):
            c = connect(port, host)
            c.sendall(payload)
            got = recv_exact(c, len(payload))
            c.close()
            return got == payload

        t.check(ping(p4, "127.0.0.1", os.urandom(100)), "RT-1a an IPv4 client gets its 100 bytes echoed")
        if v6:
            t.check(ping(p6, "::1", os.urandom(100)), "RT-1a an IPv6 client gets its 100 bytes echoed")

        # 200 sequential connections per listener: every one succeeds.
        bad = 0
        for i in range(200):
            if not ping(p4, "127.0.0.1", bytes([i % 256]) * 50):
                bad += 1
        t.check(bad == 0, "RT-1a 200 sequential IPv4 connections all succeed")
        if v6:
            bad = 0
            for i in range(200):
                if not ping(p6, "::1", bytes([i % 256]) * 50):
                    bad += 1
            t.check(bad == 0, "RT-1a 200 sequential IPv6 connections all succeed")

        expected = 1 + 200 + ((1 + 200) if v6 else 0)
        got = server.wait_stat("accepted", lambda v: v >= expected, timeout=4)
        t.check(got == expected, f"RT-1a the worker counted {expected} accepted connections (saw {got})")
        t.check(backend.accepted == expected, f"RT-1a the backend saw {expected} connections (saw {backend.accepted})")

        # No extra sockets: a port nobody configured refuses.
        other = free_port()
        refused = False
        try:
            connect(other, timeout=2).close()
        except ConnectionRefusedError:
            refused = True
        t.check(refused, "RT-1a a port nobody configured refuses connections")
        t.check(not server.stderr, f"RT-1a the worker wrote nothing to stderr ({server.stderr[:2]})")
    finally:
        server.stop()
        backend.stop()

t.run(body)
t.finish()
