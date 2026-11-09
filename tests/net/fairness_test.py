#!/usr/bin/env python3
# Proves: RT-5f   (one busy connection cannot starve the others: with a 1 GB stream through the worker and 100 small
#                  request/reply clients on the same worker, the small requests' p99 latency stays under 10 ms)
#
#     tests/net/fairness_test.py
#
# One forward_server worker, two listeners: A forwards to a backend that streams 1 GB as fast as it can, B to an echo backend.
# The 1 GB reader runs in its own process (a Python thread would compete with the latency measurement for the GIL); the 100
# small clients are driven by ONE thread with selectors, each sending 64 bytes about every 10 ms and timing the echo.
# The baseline (same clients, no stream) is measured first and reported, so a slow driver shows up as a slow baseline.
import os, selectors, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("fairness_test", "RT-5f")
host_lock()

GB = 1 << 30
READER = r'''
import socket, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
buf = bytearray(4 << 20)
got = 0
while got < int(sys.argv[2]):
    n = c.recv_into(buf)
    if not n: break
    got += n
print(got)
'''

def stream_handler(c):
    chunk = b"\0" * (1 << 20)
    try:
        for _ in range(1024):
            c.sendall(chunk)
    except OSError:
        pass
    return "streamed"

def small_clients(port, seconds, n=100):
    """n connections, 64-byte request/reply every ~10 ms each; returns the list of latencies in ms."""
    sel = selectors.DefaultSelector()
    state = {}
    for i in range(n):
        c = connect(port, timeout=10)
        c.setblocking(False)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        state[c] = {"sent_at": None, "got": 0, "next": time.perf_counter() + (i % 10) * 0.001}
        sel.register(c, selectors.EVENT_READ)
    lat = []
    end = time.perf_counter() + seconds
    payload = b"x" * 64
    while time.perf_counter() < end:
        now = time.perf_counter()
        for c, st in state.items():
            if st["sent_at"] is None and now >= st["next"]:
                st["sent_at"] = now; st["got"] = 0
                c.send(payload)
        for key, _ in sel.select(0.001):
            c = key.fileobj
            st = state[c]
            d = c.recv(64 - st["got"])
            if not d:
                raise EOFError("a small client was closed")
            st["got"] += len(d)
            if st["got"] == 64:
                lat.append((time.perf_counter() - st["sent_at"]) * 1000)
                st["sent_at"] = None
                st["next"] = time.perf_counter() + 0.010
    for c in state: c.close()
    return lat

def p99(xs):
    xs = sorted(xs)
    return xs[int(len(xs) * 0.99) - 1] if xs else float("inf")

def rt5f():
    bulk_port, echo_port, pa, pb = free_port(), free_port(), free_port(), free_port()
    bulk = ThreadedBackend(bulk_port, stream_handler)
    echo = EchoBackend(echo_port)
    server = Server([], [], workers=1, routes=[(f"127.0.0.1:{pa}", [f"127.0.0.1:{bulk_port}"]), (f"127.0.0.1:{pb}", [f"127.0.0.1:{echo_port}"])])
    try:
        server.start().wait_ready()
        base = small_clients(pb, 3)
        t.note(f"RT-5f baseline (no stream): {len(base)} requests, p50 {sorted(base)[len(base) // 2]:.2f} ms, p99 {p99(base):.2f} ms, max {max(base):.2f} ms")
        reader = subprocess.Popen([sys.executable, "-c", READER, str(pa), str(GB)], stdout=subprocess.PIPE, text=True)
        time.sleep(0.3)                                    # the stream is flowing
        lat = []
        t0 = time.time()
        while reader.poll() is None and time.time() - t0 < 120:
            lat += small_clients(pb, 1)
        took = time.time() - t0
        out = reader.communicate(timeout=30)[0].strip()
        t.check(out == str(GB), f"RT-5f the 1 GB stream arrived whole ({out} bytes in {took:.1f}s = {GB / took / 1e6:.0f} MB/s)")
        t.check(len(lat) > 500, f"RT-5f the small clients made {len(lat)} requests while the stream ran")
        t.note(f"RT-5f with the stream: p50 {sorted(lat)[len(lat) // 2]:.2f} ms, p99 {p99(lat):.2f} ms, max {max(lat):.2f} ms")
        t.check(p99(lat) < 10, f"RT-5f small requests' p99 latency under a 1 GB stream is below 10 ms ({p99(lat):.2f} ms; baseline {p99(base):.2f} ms)")
        t.check(server.alive() and not server.stderr, "RT-5f the worker is up and silent")
    finally:
        server.stop(); bulk.stop(); echo.stop()

t.run(rt5f)
t.finish()
