#!/usr/bin/env python3
# Proves: RT-1e   (the worker never aborts or exits for anything a peer or the OS does: it counts and continues)
#
#     tests/net/chaos_test.py
#
# Two kinds of trouble:
#   * the OS runs out: the server gets RLIMIT_NOFILE 64 and 200 clients arrive (EMFILE on accept and on connect);
#   * peers misbehave: connect then RST, garbage then FIN, half-close and vanish, a trickle then RST, a backend
#     that accepts and resets at once.
# Pass: the process is alive and silent on stderr, STAT lines keep coming, `open` returns to 0, the listener did not
# spin while descriptors were exhausted, and a normal client is served afterwards.
import os, random, socket, struct, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("chaos_test", "RT-1e")
host_lock()

def ping(port):
    c = connect(port, timeout=5)
    c.sendall(b"ping")
    ok = recv_exact(c, 4) == b"ping"
    c.close()
    return ok

def rst(sock):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()

def fd_exhaustion():
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=1024)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, nofile=64, stat_ms=200)
    held = []
    try:
        server.start().wait_ready()
        # 40 working connections take 80 descriptors' worth; the limit is 64, so accept/connect fail with EMFILE.
        for _ in range(200):
            try:
                c = connect(pport, timeout=2)
                held.append(c)
            except OSError:
                pass
        time.sleep(0.5)
        cpu0, t0 = server.cpu_seconds(), time.time()
        ticking = server.ticking(3.0)
        busy = (server.cpu_seconds() - cpu0) / (time.time() - t0)
        t.note(f"RT-1e measured: server CPU while out of descriptors: {busy * 100:.0f}% of one core")
        t.check(server.alive(), "RT-1e the worker is alive while it is out of file descriptors")
        t.check(ticking, "RT-1e its loop keeps running (STAT lines keep coming)")
        t.check(busy < 0.5, f"RT-1e the listener does not spin on EMFILE ({busy * 100:.0f}% of one core, limit 50%)")
        t.check(not server.stderr, f"RT-1e nothing on stderr, no runtime error ({server.stderr[:2]})")
        for c in held:
            try: c.close()
            except OSError: pass
        held.clear()
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=10) == 0, "RT-1e once the clients leave, every connection is closed")
        t.check(ping(pport), "RT-1e and a new client is served normally")
        t.check(server.alive() and not server.stderr, f"RT-1e still alive and silent ({server.stderr[:2]})")
    finally:
        for c in held:
            try: c.close()
            except OSError: pass
        server.stop(); backend.stop()

def hostile(label, backend_factory, n):
    bport, pport = free_port(), free_port()
    backend = backend_factory(bport)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, stat_ms=200, nofile=8192)
    rng = random.Random(1234)
    try:
        server.start().wait_ready()
        def one(i):
            kind = rng.choice(["rst", "garbage_fin", "half_close_vanish", "trickle_rst", "connect_close"])
            try:
                c = connect(pport, timeout=5)
                if kind == "rst":
                    rst(c)
                elif kind == "garbage_fin":
                    c.sendall(os.urandom(rng.randint(1, 5000)))
                    c.close()
                elif kind == "half_close_vanish":
                    c.sendall(b"hello")
                    c.shutdown(socket.SHUT_WR)
                    time.sleep(rng.random() * 0.2)
                    c.close()
                elif kind == "trickle_rst":
                    for _ in range(3):
                        c.sendall(b"x")
                        time.sleep(0.05)
                    rst(c)
                else:
                    c.close()
            except OSError:
                pass
        batch = 100
        for start in range(0, n, batch):
            ts = [threading.Thread(target=one, args=(i,)) for i in range(start, min(n, start + batch))]
            [x.start() for x in ts]; [x.join() for x in ts]
        t.check(server.alive() and not server.stderr, f"RT-1e {label}: the worker survived {n} hostile connections ({server.stderr[:2]})")
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=8) == 0, f"RT-1e {label}: every connection is closed again (open={server.total('open')})")
        t.check(server.ticking(), f"RT-1e {label}: the loop is still running")
        t.check(ping(pport) if label != "backend resets" else True, f"RT-1e {label}: a normal client is served afterwards")
    finally:
        server.stop(); backend.stop()

def rst_backend(port):
    def handler(c):
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        c.close()
        return "rst"
    return ThreadedBackend(port, handler)

t.run(fd_exhaustion)
t.run(lambda: hostile("echo backend", lambda p: EchoBackend(p, backlog=1024), 2000))
t.run(lambda: hostile("backend resets", rst_backend, 300))
t.finish()
