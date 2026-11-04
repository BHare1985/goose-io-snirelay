#!/usr/bin/env python3
# Proves: RT-2b   (an event or handle with an old generation never touches the connection now in that slot)
#
#     tests/net/generation_test.py        (CYCLES=100000 for a quick local run; the row says 1,000,000)
#
# 1,000,000 short connections through one worker, so every slot is reused thousands of times, with random RSTs at
# random moments. Every client sends its own 16-byte tag and must read back exactly that tag: a stale event that
# touched a reused slot would show as another connection's bytes, a hang, or a reset of the wrong connection.
# The backend is the test-only C echo server (harness/echo_server.c); Python cannot accept 100,000 connections a second.
# RT-2c, the out-of-range and stale events fed to the dispatcher directly, is tests/unit/generation_test.goose.
import multiprocessing, os, random, socket, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

CYCLES = int(os.environ.get("CYCLES", "1000000"))
PROCS = 8

def client_process(port, first, count, seed, out):
    rng = random.Random(seed)
    wrong = hangs = errors = 0
    linger0 = struct.pack("ii", 1, 0)
    for k in range(count):
        tag = struct.pack(">QQ", first + k, rng.getrandbits(64))
        mode = rng.randrange(4)
        try:
            c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            c.settimeout(10)
            c.connect(("127.0.0.1", port))
            if mode == 0:                                  # connect, RST at once
                c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger0)
            elif mode == 1:                                # send, RST without reading
                c.sendall(tag)
                c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger0)
            else:                                          # send, read the tag back, then FIN (2) or RST (3)
                c.sendall(tag)
                got = b""
                while len(got) < 16:
                    d = c.recv(16 - len(got))
                    if not d:
                        break
                    got += d
                if got != tag:
                    wrong += 1
                if mode == 3:
                    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger0)
            c.close()
        except socket.timeout:
            hangs += 1
        except OSError:
            errors += 1
    out.put((wrong, hangs, errors))

if __name__ == "__main__":
    t = Test("generation_test", "RT-2b")
    host_lock()
    def body():
        raise_nofile(65536)
        bport, pport = free_port(), free_port()
        backend = ProcessBackend(bport)
        server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, stat_ms=500, nofile=65536)
        try:
            server.start().wait_ready()
            q = multiprocessing.Queue()
            per = CYCLES // PROCS
            t0 = time.time()
            ps = [multiprocessing.Process(target=client_process, args=(pport, i * per, per, 100 + i, q)) for i in range(PROCS)]
            [p.start() for p in ps]
            res = [q.get(timeout=1800) for _ in ps]
            [p.join() for p in ps]
            took = time.time() - t0
            wrong = sum(r[0] for r in res); hangs = sum(r[1] for r in res); errors = sum(r[2] for r in res)
            total = per * PROCS
            t.note(f"RT-2b measured: {total} connections in {took:.0f}s = {total / took:.0f}/s; wrong tags {wrong}, hangs {hangs}, errors {errors}")
            t.check(wrong == 0, f"RT-2b no client ever read another connection's bytes (wrong tags: {wrong})")
            t.check(hangs == 0, f"RT-2b no client hung (hangs: {hangs})")
            accepted = server.wait_stat("accepted", lambda v: v >= total - errors, timeout=10)
            t.check(accepted >= total - errors and accepted <= total, f"RT-2b the worker accepted every connection that connected ({accepted} of {total}, {errors} client-side errors)")
            t.check(server.wait_stat("open", lambda v: v == 0, timeout=15) == 0, f"RT-2b every connection is closed at the end (open={server.total('open')})")
            t.check(server.alive() and not server.stderr, f"RT-2b the worker is up and silent ({server.stderr[:2]})")
            t.check(ping_ok(pport), "RT-2b a normal client is served afterwards")
        finally:
            server.stop(); backend.stop()
    def ping_ok(port):
        c = connect(port, timeout=5); c.sendall(b"ping"); ok = recv_exact(c, 4) == b"ping"; c.close(); return ok
    t.run(body)
    t.finish()
