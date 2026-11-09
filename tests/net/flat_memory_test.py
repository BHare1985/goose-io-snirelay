#!/usr/bin/env python3
# Proves: RT-5g   (no allocation on the established forwarding path: the worker's memory is flat while 10 GB is forwarded)
#
#     tests/net/flat_memory_test.py
#
# A single-worker forward_server forwards 10 GB (20 connections x 512 MB, in both directions: the echo backend sends it back)
# after a warm-up of 1 GB. Resident memory (VmRSS and the high-water mark VmHWM), the buffer pool size and the number of
# buffers in use are read before and after the 10 GB; growth beyond a small allowance fails the row.
import os, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("flat_memory_test", "RT-5g")
host_lock()

def status(pid, key):
    for l in open(f"/proc/{pid}/status"):
        if l.startswith(key):
            return int(l.split()[1])

def push(port, total):
    c = connect(port, timeout=120)
    chunk = b"y" * (1 << 20)
    done = threading.Event()
    got = [0]
    def rd():
        while got[0] < total:
            d = c.recv(1 << 20)
            if not d: break
            got[0] += len(d)
        done.set()
    threading.Thread(target=rd, daemon=True).start()
    sent = 0
    while sent < total:
        c.sendall(chunk); sent += len(chunk)
    done.wait(120)
    c.close()
    return got[0]

def run(total_per_conn, conns):
    bport, pport = free_port(), free_port()
    return bport, pport

def rt5g():
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=1024)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, stat_ms=200)
    try:
        server.start().wait_ready()
        pid = server.proc.pid
        def burst(per, n):
            res = run_threads([lambda: push(pport, per) for _ in range(n)], join_timeout=600)
            return [r for r in res if not isinstance(r, Exception)]
        burst(256 << 20, 4)                                          # warm-up: 1 GB, the pool grows to what the load needs
        time.sleep(1.0)
        rss0, hwm0, bufs0 = status(pid, "VmRSS"), status(pid, "VmHWM"), server.total("buffers_total")
        t0 = time.time()
        done = burst(512 << 20, 20)
        took = time.time() - t0
        time.sleep(1.0)
        rss1, hwm1, bufs1 = status(pid, "VmRSS"), status(pid, "VmHWM"), server.total("buffers_total")
        moved = sum(done)
        t.check(len(done) == 20 and all(d == 512 << 20 for d in done), f"RT-5g 20 connections each sent and got back 512 MB ({len(done)} finished; {moved >> 20} MB echoed back in {took:.0f}s)")
        t.note(f"RT-5g measured: RSS {rss0} -> {rss1} kB, high-water {hwm0} -> {hwm1} kB, pool {bufs0} -> {bufs1} buffers, over {2 * moved / 1e9:.1f} GB forwarded (both directions)")
        t.check(bufs1 <= bufs0 + 64, f"RT-5g the buffer pool did not keep growing ({bufs0} -> {bufs1} buffers)")
        t.check(rss1 - rss0 <= 2048, f"RT-5g resident memory is flat across 10 GB: {rss0} -> {rss1} kB (allowance 2 MB)")
        t.check(hwm1 - hwm0 <= 2048 + 20 * 64, f"RT-5g ... and so is its high-water mark: {hwm0} -> {hwm1} kB")
        t.check(server.total("buffers_in_use") == 0, f"RT-5g every buffer is back in the pool at the end ({server.total('buffers_in_use')} in use)")
        t.check(server.alive() and not server.stderr, "RT-5g the worker is up and silent")
    finally:
        server.stop(); backend.stop()

t.run(rt5g)
t.finish()
