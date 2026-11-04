#!/usr/bin/env python3
# Proves: RT-4e RT-5e RT-9a RT-9c RT-9d   (handler mode: event order, close vs reset, send backpressure, Tick, forward)
#
#     tests/net/handler_test.py
#
# The system under test is harness/handler_server.goose, a server written the way a user would write one; the tag of the
# route that accepts a connection picks what it does (echo, send 1 MB then close, flood 64 MB, forward, reset). With
# --log-events it prints one line per event, which these tests read; the clients are independent Python code.
import hashlib, os, random, socket, struct, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("handler_test", "RT-4e RT-5e RT-9a RT-9c RT-9d")
host_lock()
MB = 1 << 20

def fnv(data, h=14695981039346656037):
    for b in data:
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h

BLOCK = bytes((i * 31 + 7) % 251 for i in range(251))      # the server's pattern repeats every 251 bytes
def pattern(offset, n):
    start = offset % 251
    reps = (start + n) // 251 + 2
    return (BLOCK * reps)[start:start + n]

def handler(ports_tags, **kw):
    ports = {tag: free_port() for tag in ports_tags}
    handles = [f"127.0.0.1:{p}={tag}" for tag, p in ports.items()]
    srv = Server([], [], exe=HANDLER_SERVER, handles=handles, extra=["--log-events"] + kw.pop("extra", []), **kw)
    return ports, srv

def event_lines(server):
    with server._lock:
        return [l for l in server.lines if l.startswith("E ")]

# ----------------------------------------------------------------------------------------------- RT-9a

def rt9a():
    ports, server = handler([1], stat_ms=500, nofile=4096)
    try:
        server.start().wait_ready()
        rng = random.Random(99)
        expected = []
        lock = threading.Lock()
        def client(i):
            sizes = [rng.randint(1, 5000) for _ in range(rng.randint(1, 3))]
            chunks = [os.urandom(n) for n in sizes]
            c = connect(ports[1], timeout=20)
            for ch in chunks:
                c.sendall(ch)
                time.sleep(0.001)
            data = b"".join(chunks)
            got = recv_exact(c, len(data))
            c.close()
            with lock:
                expected.append((len(data), fnv(data)))
            return got == data
        results = []
        pool = []
        def run_batch(lo, hi):
            for i in range(lo, hi):
                try:
                    results.append(client(i))
                except (OSError, EOFError):
                    results.append(False)
        ts = [threading.Thread(target=run_batch, args=(k * 25, (k + 1) * 25)) for k in range(40)]
        [x.start() for x in ts]; [x.join() for x in ts]
        t.check(len(results) == 1000 and all(results), f"RT-9a 1,000 echo connections all come back byte-exact ({sum(1 for r in results if r)}/1000)")
        deadline = time.time() + 10
        while time.time() < deadline and sum(1 for l in event_lines(server) if l.startswith("E closed")) < 1000:
            time.sleep(0.1)
        lines = event_lines(server)
        per = {}
        bad_order = 0
        for l in lines:
            parts = l.split()
            if parts[1] in ("tick",):
                continue
            key = parts[2]
            per.setdefault(key, []).append(parts)
        closed_info = []
        for key, evs in per.items():
            kinds = [e[1] for e in evs]
            if kinds[0] != "open" or kinds.count("open") != 1 or kinds.count("closed") != 1 or kinds[-1] != "closed" \
               or any(k not in ("open", "data", "writable", "closed") for k in kinds):
                bad_order += 1
                continue
            total = sum(int(e[3][2:]) for e in evs if e[1] == "data")
            c = evs[-1]
            ctotal = int(c[3].split("=")[1]); cfnv = int(c[4].split("=")[1])
            if total != ctotal:
                bad_order += 1
            closed_info.append((ctotal, cfnv))
        t.check(len(per) == 1000, f"RT-9a the server saw 1,000 distinct connections (saw {len(per)})")
        t.check(bad_order == 0, f"RT-9a every connection: Opened first, Data in between, exactly one Closed last, nothing after ({bad_order} violations)")
        t.check(sorted(closed_info) == sorted(expected), "RT-9a the bytes the handler received, in order (length and FNV-1a), equal what each client sent")
        t.check(server.alive() and not server.stderr, f"RT-9a the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop()

# ----------------------------------------------------------------------------------------------- RT-9c

def rt9c():
    ports, server = handler([2, 6], stat_ms=500)
    try:
        server.start().wait_ready()
        c = connect(ports[2], timeout=20)
        got = bytearray()
        c.settimeout(20)
        while True:
            d = c.recv(1 << 16)
            if not d:
                break
            got += d
        c.close()
        t.check(bytes(got) == pattern(0, MB), f"RT-9c close sends the queued bytes first: all 1 MB arrives, then EOF ({len(got)} bytes)")
        # reset: the client sees ECONNRESET at once
        c = connect(ports[6], timeout=5)
        c.settimeout(3)
        t0 = time.time()
        try:
            d = c.recv(10)
            outcome = "eof" if d == b"" else "data"
        except ConnectionResetError:
            outcome = "reset"
        except socket.timeout:
            outcome = "hung"
        c.close()
        t.check(outcome == "reset" and time.time() - t0 < 1.0, f"RT-9c reset ends the connection with an RST at once ({outcome} after {time.time()-t0:.2f}s)")
        t.check(server.alive() and not server.stderr, f"RT-9c the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop()

# ----------------------------------------------------------------------------------------------- RT-5e

def rt5e():
    ports, server = handler([3], stat_ms=500)
    TOTAL = 64 * MB
    try:
        server.start().wait_ready()
        time.sleep(0.5)
        base = server.rss_kb()
        c = connect(ports[3], timeout=30)
        time.sleep(2.0)                                  # the client does not read: the server's sends must be refused
        grown = server.rss_kb() - base
        sent_all = [l for l in event_lines(server) if l.startswith("E sent-all")]
        t.note(f"RT-5e measured: server RSS grew {grown} kB while the client read nothing for 2 s; sent-all so far: {len(sent_all)}")
        t.check(not sent_all, "RT-5e the 64 MB is not all sent while the client reads nothing: sends are refused")
        t.check(grown < 1024, f"RT-5e the server's memory stays bounded: RSS grew {grown} kB (limit 1024 kB)")
        # now read everything and check it
        c.settimeout(60)
        offset = 0
        ok = True
        while offset < TOTAL:
            d = c.recv(1 << 20)
            if not d:
                break
            if d != pattern(offset, len(d)):
                ok = False
                break
            offset += len(d)
        eof = c.recv(1) == b""
        c.close()
        t.check(ok and offset == TOTAL, f"RT-5e once the client reads, all 64 MB arrives in order ({offset} bytes, pattern {'ok' if ok else 'WRONG'})")
        t.check(eof, "RT-5e and then EOF (close delivered the queue first)")
        time.sleep(0.5)
        done = [l for l in event_lines(server) if l.startswith("E sent-all")]
        if t.check(len(done) == 1, "RT-5e the handler reported finishing"):
            falses = int(done[0].split("falses=")[1].split()[0]); writables = int(done[0].split("writables=")[1])
            t.note(f"RT-5e measured: send returned false {falses} times, Writable arrived {writables} times")
            t.check(falses > 0, f"RT-5e send returned false at the per-connection cap (falses={falses})")
            t.check(writables > 0, f"RT-5e Writable followed once the queue drained (writables={writables})")
        t.check(server.alive() and not server.stderr, f"RT-5e the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop()

# ----------------------------------------------------------------------------------------------- RT-9d

def rt9d():
    ports, server = handler([1], stat_ms=500, nofile=4096)
    try:
        server.start().wait_ready()
        stop = time.time() + 5
        def pinger(i):
            c = connect(ports[1], timeout=10)
            n = 0
            while time.time() < stop:
                c.sendall(b"x" * 1024)
                recv_exact(c, 1024)
                n += 1
            c.close()
            return n
        results = run_threads([lambda i=i: pinger(i) for i in range(50)])
        ticks = [int(l.split()[2]) for l in event_lines(server) if l.startswith("E tick")]
        gaps = [b - a for a, b in zip(ticks, ticks[1:])]
        worst = max(gaps) if gaps else 0
        t.note(f"RT-9d measured: {len(ticks)} ticks, largest gap {worst} ms, {sum(r for r in results if isinstance(r, int))} echoes under load")
        t.check(all(isinstance(r, int) and r > 0 for r in results), "RT-9d the 50 busy connections all kept working")
        t.check(len(ticks) >= 40, f"RT-9d Tick arrived about every 100 ms for 5 s ({len(ticks)} ticks, expected >= 40)")
        t.check(worst <= 250, f"RT-9d no gap between Ticks over 250 ms ({worst} ms)")
    finally:
        server.stop()

# ----------------------------------------------------------------------------------------------- RT-4e

def rt4e():
    seen = []
    def backend_handler(c):
        c.settimeout(3)
        got = b""
        try:
            while len(got) < 5:
                d = c.recv(100)
                if not d: break
                got += d
            c.sendall(b"FROM-BACKEND:" + got)
        except socket.timeout:
            pass
        return got
    bport = free_port()
    backend = ThreadedBackend(bport, backend_handler)
    ports, server = handler([4, 5], extra=["--forward-to", f"127.0.0.1:{bport}"])
    try:
        server.start().wait_ready()
        # tag 4: forwarded on Opened, before a byte was consumed
        c = connect(ports[4], timeout=10)
        c.sendall(b"hello")
        got = recv_exact(c, len(b"FROM-BACKEND:hello"))
        c.close()
        t.check(got == b"FROM-BACKEND:hello", f"RT-4e forward on Opened: the client talks to the backend ({got!r})")
        time.sleep(0.3)
        lines = event_lines(server)
        t.check(any(l.startswith("E forward") and l.endswith("result=true") for l in lines), "RT-4e forward on Opened returned true")
        t.check(not any(l.startswith("E data") for l in lines), "RT-4e the handler saw no Data for a forwarded connection")
        # tag 5: a byte is consumed first, then forward must be refused and the connection stays a handler connection
        before = len(backend.results)
        c = connect(ports[5], timeout=10)
        c.sendall(b"x")
        first = recv_exact(c, 1)
        c.sendall(b"yz")
        rest = recv_exact(c, 2)
        c.close()
        t.check(first + rest == b"xyz", f"RT-4e after a byte was consumed the connection is still served by the handler: echo ({first + rest!r})")
        time.sleep(0.3)
        lines = event_lines(server)
        t.check(any(l.startswith("E forward") and l.endswith("result=false") for l in lines), "RT-4e forward after Data returned false")
        t.check(len(backend.results) == before, "RT-4e ... and the backend was never contacted for it")
        t.check(server.alive() and not server.stderr, f"RT-4e the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

t.run(rt9a)
t.run(rt9c)
t.run(rt5e)
t.run(rt9d)
t.run(rt4e)
t.finish()
