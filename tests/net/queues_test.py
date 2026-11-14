#!/usr/bin/env python3
# Proves: RT-18a RT-18b   (the engine's internal work lists stay bounded under sustained load)
#
# Why: the list of connections that still have bytes to move (`ready`) and the list of reads waiting for a pool buffer were emptied only when
# their head caught up with their tail. A connection that always has more to move (it hits the per-wakeup budget on every pass) re-queues itself
# before the head reaches the end, so the list grew by one entry per pass for as long as the load lasted. STAT lines report `ready_len` and
# `waiting_len`, the lengths of the two lists, sampled every 200 ms while the load runs.
#     tests/run_tests.sh queues
import os, socket, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("queues_test", "RT-18a RT-18b")
host_lock()
BOUND = 64

def sink(c):
    c.settimeout(10)
    n = 0
    try:
        while True:
            d = c.recv(1 << 20)
            if not d: break
            n += len(d)
    except OSError: pass
    return n

def slow_sink(c):                       # reads 16 KB per 2 ms: the proxy's writes to it stall, so its buffers stay held
    c.settimeout(10)
    n = 0
    try:
        while True:
            d = c.recv(16384)
            if not d: break
            n += len(d); time.sleep(0.002)
    except OSError: pass
    return n

def load(clients, seconds, backend_fn=sink, **server_args):
    bport, pport = free_port(), free_port()
    backend = ThreadedBackend(bport, backend_fn)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, stat_ms=200, **server_args)
    try:
        server.start().wait_ready()
        stop = time.time() + seconds
        chunk = b"x" * (1 << 20)
        def push():
            s = socket.create_connection(("127.0.0.1", pport), timeout=10)
            try:
                while time.time() < stop: s.sendall(chunk)
            except OSError: pass
            s.close()
        threads = [threading.Thread(target=push) for _ in range(clients)]
        for th in threads: th.start()
        peak_ready = peak_wait = 0; samples = 0; waits = 0
        while time.time() < stop:
            time.sleep(0.2)
            peak_ready = max(peak_ready, server.stat_of(0, "ready_len")); peak_wait = max(peak_wait, server.stat_of(0, "waiting_len"))
            samples += 1
        waits = server.stat_of(0, "buffer_waits")
        for th in threads: th.join(15)
        return peak_ready, peak_wait, waits, samples
    finally:
        server.stop(); backend.stop()

def body():
    ready, waiting, waits, samples = load(1, 4)
    t.check(samples >= 15, f"RT-18a setup: the load ran for {samples} samples")
    t.check(ready <= BOUND, f"RT-18a one connection that always has more to move: the ready list stays at most {BOUND} long (peak {ready})")
    ready, waiting, waits, samples = load(16, 4, slow_sink, buffers=2, buffer_size=4096)
    t.check(waits > 100, f"RT-18b setup: the pool of 2 buffers made reads wait ({waits} waits)")
    t.check(waiting <= BOUND and ready <= BOUND, f"RT-18b a saturated pool: the waiting-reads list and the ready list stay at most {BOUND} long (peaks {waiting}, {ready})")

t.run(body)
t.finish()
