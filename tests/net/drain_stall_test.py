#!/usr/bin/env python3
# Proves: RT-8f   (NON-GATING measurement: during a drain a connect can stall for the kernel's 1 s SYN retransmit; this reports how often)
#
#     tests/net/drain_stall_test.py [iterations]      (default 60)
#
# Known kernel behaviour: a SYN that reaches an SO_REUSEPORT listener in the instant it closes is dropped, and the client's SYN is retransmitted after 1 s
# (c_proxy's proxy.c calls it "the classic SO_REUSEPORT handover race"). The engine closes its listeners at once on a drain; this test sends SIGTERM and
# probes with connects every 20 ms and counts the iterations whose FIRST probe stalled for its whole 1 s timeout. It never fails on the rate: it prints it.
# Measured 2026-11-12: 3 stalls in 120 iterations once, then 0 in 600. The staged-close improvement (detach the reuseport group first) is in TODO.md.
import os, signal, socket, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("drain_stall_test", "RT-8f")
host_lock()
N = int(sys.argv[1]) if len(sys.argv) > 1 else 60

def first_probe(port):
    t0 = time.time()
    try:
        connect(port, timeout=1).close(); return "connected", time.time() - t0
    except ConnectionRefusedError: return "refused", time.time() - t0
    except OSError: return "stalled", time.time() - t0

def body():
    stalls = 0; done = 0
    for _ in range(N):
        bport, port = free_port(), free_port()
        echo = EchoBackend(bport)
        a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--drain-ms", "2000"])
        try:
            a.start().wait_ready()
            held = connect(port, timeout=10)
            a.proc.send_signal(signal.SIGTERM)
            what, took = first_probe(port)
            stalls += what == "stalled"; done += 1
        finally:
            a.stop(); echo.stop()
    t.note(f"RT-8f measured: {stalls} of {done} iterations had a first connect after SIGTERM that stalled the whole 1 s (known kernel behaviour, not gating)")
    t.check(done == N, f"RT-8f the measurement ran {done} of {N} iterations")

t.run(body)
t.finish()
