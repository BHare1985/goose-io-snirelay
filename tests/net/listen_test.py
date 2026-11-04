#!/usr/bin/env python3
# Proves: RT-1a RT-1b RT-1d   (listens on IPv4 and IPv6; N workers share one port; a port held by another process is an error)
#
#     tests/net/listen_test.py        (run_tests.sh builds harness/forward_server and sets FORWARD_SERVER)
#
# RT-1a: one worker, a listener on 127.0.0.1 and one on [::1], both forwarding to an echo backend.
# RT-1b: four workers on one port share 400 connections: each gets at least 50.
# RT-1d: while another process holds the port, starting fails with an error that names the address, and the
#        process that held it keeps every one of its connections (we steal none).
import os, socket, subprocess, sys, time
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

def rt1b():
    backend_port, port = free_port(), free_port()
    backend = EchoBackend(backend_port)
    server = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{backend_port}"], workers=4, stat_ms=200)
    try:
        server.start().wait_ready()
        bad = 0
        for i in range(400):
            c = connect(port)
            c.sendall(b"x")
            if recv_exact(c, 1) != b"x":
                bad += 1
            c.close()
        t.check(bad == 0, "RT-1b all 400 connections were served")
        server.wait_stat("accepted", lambda v: v >= 400, timeout=4)
        per = [server.stat_of(i, "accepted") for i in range(4)]
        t.note(f"RT-1b measured: accepts per worker {per} (sum {sum(per)})")
        t.check(sum(per) == 400, f"RT-1b the workers accepted 400 connections in all ({sum(per)})")
        t.check(min(per) >= 50, f"RT-1b every worker accepted at least 50 of 400 (per worker: {per})")
        t.check(server.alive() and not server.stderr, f"RT-1b all four workers are up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

def holder(port, reuseport):
    """Another process's listener, as a plain socket in this one."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if reuseport:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("127.0.0.1", port))
    s.listen(512)
    return s

def rt1d():
    for reuseport in (False, True):
        backend_port = free_port()
        backend = EchoBackend(backend_port)
        port = free_port()
        held = holder(port, reuseport)
        server = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{backend_port}"], workers=2)
        what = "with SO_REUSEPORT" if reuseport else "without SO_REUSEPORT"
        try:
            server.start()
            try:
                server.proc.wait(timeout=6)
            except subprocess.TimeoutExpired:
                pass
            t.check(not server.alive(), f"RT-1d starting while another process holds the port ({what}) fails: the program exits")
            t.check(server.proc.returncode == 1, f"RT-1d ... with status 1 (got {server.proc.returncode})")
            time.sleep(0.2)
            err = " ".join(server.stderr)
            t.check(f"127.0.0.1:{port}" in err and "Address already in use" in err,
                    f"RT-1d ... and an error that names the address and says why ({err[:150]!r})")
            # We stole nothing: every connection goes to the holder.
            before = len(server.ready)
            for i in range(50):
                c = connect(port)
                c.close()
            held.settimeout(2)
            got = 0
            try:
                while got < 50:
                    a, _ = held.accept()
                    a.close()
                    got += 1
            except socket.timeout:
                pass
            t.check(got == 50 and before == 0, f"RT-1d the process that held the port ({what}) still gets all its connections ({got}/50)")
        finally:
            server.stop(); held.close(); backend.stop()

t.run(body)
t.run(rt1b)
t.run(rt1d)
t.finish()
