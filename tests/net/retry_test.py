#!/usr/bin/env python3
# Proves: RT-4c RT-4d   (a refused connect is retried on the next target before any client byte is consumed;
#                        when every target fails the client is closed)
#
#     tests/net/retry_test.py
#
# RT-4c here covers REFUSED connects. Its TIMED-OUT half needs the connect timeout (RT-7a, milestone M4) and is added to
# this file then; the row is `done` only after both halves have run.
#
# The targets are listed in order; the built-in policy starts connection k at address k mod n and moves on to the next
# address (wrapping) after each failure, until every address has been tried once. The test simulates that to know how many
# failures to expect, and checks the server's own counters against it.
import hashlib, os, socket, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("retry_test", "RT-4c RT-4d")
host_lock()

def simulate(order, connections):
    """order: list of 'R' (refused) / 'G' (good). Returns (failures, retries) after `connections` connections."""
    failures = retries = 0
    for k in range(connections):
        start = k % len(order)
        for step in range(len(order)):
            if order[(start + step) % len(order)] == "G":
                break
            failures += 1
            if step + 1 < len(order):
                retries += 1
    return failures, retries

def check_order(order):
    n = 9
    good_port = free_port()
    backend = EchoBackend(good_port)
    refused = [free_port() for _ in order]
    targets = [f"127.0.0.1:{good_port if o == 'G' else refused[i]}" for i, o in enumerate(order)]
    pport = free_port()
    server = Server([f"127.0.0.1:{pport}"], targets, workers=1, stat_ms=200)
    label = "".join(order)
    try:
        server.start().wait_ready()
        ok = 0
        for k in range(n):
            c = connect(pport, timeout=10)
            payload = os.urandom(100_000)
            got = bytearray()
            try:
                c.sendall(payload)                   # right away, before the connect to a good target can be finished
                c.shutdown(socket.SHUT_WR)
                while True:
                    d = c.recv(65536)
                    if not d:
                        break
                    got += d
            except OSError:
                pass                                 # the proxy closed us: the payload did not arrive
            c.close()
            if bytes(got) == payload:
                ok += 1
        t.check(ok == n, f"RT-4c targets [{label}]: all {n} clients get their 100 KB echoed intact and in order ({ok}/{n})")
        failures, retries = simulate(order, n)
        f = server.wait_stat("connect_failures", lambda v: v >= failures, timeout=4)
        r = server.total("retries")
        t.note(f"RT-4c [{label}]: connect_failures={f} (expected {failures}), retries={r} (expected {retries})")
        t.check(f == failures, f"RT-4c targets [{label}]: connect_failures counted {failures} (saw {f})")
        t.check(r == retries, f"RT-4c targets [{label}]: retries counted {retries} (saw {r})")
        t.check(server.closed("ConnectFailed") == 0, f"RT-4c targets [{label}]: no connection was closed as ConnectFailed ({server.closed('ConnectFailed')})")
        t.check(server.alive() and not server.stderr, f"RT-4c targets [{label}]: the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

def all_refused():
    ports = [free_port() for _ in range(3)]
    pport = free_port()
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{p}" for p in ports], workers=1, stat_ms=200)
    n = 5
    try:
        server.start().wait_ready()
        worst = 0.0
        closed = 0
        for k in range(n):
            c = connect(pport, timeout=10)
            t0 = time.time()
            c.settimeout(3)
            try:
                c.sendall(b"hello?")
                d = c.recv(10)
                closed += 1 if d == b"" else 0
            except (ConnectionResetError, BrokenPipeError):
                closed += 1
            except socket.timeout:
                pass
            worst = max(worst, time.time() - t0)
            c.close()
        t.check(closed == n, f"RT-4d every target refused: all {n} clients are closed ({closed}/{n})")
        t.check(worst < 1.0, f"RT-4d ... each within 1 s ({worst:.2f}s worst)")
        cf = server.wait_stat("connect_failures", lambda v: v >= n * 3, timeout=4)
        t.check(cf == n * 3, f"RT-4d connect_failures counts every attempt: {n} connections x 3 targets = {n * 3} (saw {cf})")
        t.check(server.total("retries") == n * 2, f"RT-4d retries counts the attempts after the first: {n * 2} (saw {server.total('retries')})")
        t.check(server.wait_closed("ConnectFailed", lambda v: v == n, timeout=3) == n, f"RT-4d every connection is counted as closed by ConnectFailed ({server.closed('ConnectFailed')})")
        t.check(server.total("open") == 0, "RT-4d nothing stays open")
        t.check(server.alive() and not server.stderr, f"RT-4d the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop()

for order in ("RRG", "RGR", "GRR"):
    t.run(lambda order=order: check_order(order))
t.run(all_refused)
t.finish()
