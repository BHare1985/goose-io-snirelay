#!/usr/bin/env python3
# Proves: RT-5c RT-5d   (a destination that stops reading stops the source; an empty pool waits, never aborts)
#
#     tests/net/backpressure_test.py
#
# RT-5c: the backend accepts and never reads. A client offers 1 GB. The proxy must stop reading from the client
#        (the client's sends stall), its memory must stay flat, and once the backend reads, every byte arrives in order.
#        The measured numbers are printed on every run, so the ceilings can be tightened later.
# RT-5d: a pool of 4 buffers and 100 concurrent echo clients: all finish, the pool really ran dry, nothing aborts.
import hashlib, os, socket, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("backpressure_test", "RT-5c RT-5d")
host_lock()
MB = 1 << 20
GB = 1 << 30

def rt5c():
    bport, pport = free_port(), free_port()
    backend = HoldBackend(bport)                      # accepts, never reads
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, stat_ms=250)
    try:
        server.start().wait_ready()
        c = connect(pport, timeout=10)
        c.setblocking(False)
        time.sleep(0.5)
        baseline = server.rss_kb()
        sent_hash = hashlib.sha256()
        chunks = stream(4242, GB)
        pending = b""
        sent = 0
        deadline = time.time() + 10
        stalled_since = None
        gen_done = False
        # Offer data as fast as the socket takes it, for 10 s.
        while time.time() < deadline:
            if not pending:
                try:
                    pending = next(chunks)
                    sent_hash.update(pending)
                except StopIteration:
                    gen_done = True
                    break
            try:
                n = c.send(pending)
                sent += n
                pending = pending[n:]
            except (BlockingIOError, InterruptedError):
                time.sleep(0.01)
        grown = server.rss_kb() - baseline
        t.note(f"RT-5c measured: the client got {sent / MB:.1f} MB into the pipe in 10 s of offering 1024 MB; "
               f"proxy RSS grew {grown / 1024:.1f} MB; buffers_in_use={server.total('buffers_in_use')}")
        t.check(not gen_done and sent < 64 * MB, f"RT-5c the client's sends stall: {sent / MB:.1f} MB accepted of 1024 offered (ceiling 64 MB)")
        t.check(grown <= 8 * 1024, f"RT-5c proxy RSS grew {grown / 1024:.1f} MB while 1 GB was offered (ceiling 8 MB)")
        t.check(server.max_buffers_in_use <= 2, f"RT-5c at most one buffer per direction was pinned (max {server.max_buffers_in_use})")
        t.check(server.ticking(), "RT-5c the worker's loop is still running (STAT lines keep coming)")

        # The backend starts reading: everything offered arrives, in order.
        c.setblocking(True)
        c.settimeout(120)
        reader_result = {}
        def backend_reads():
            reader_result["n"] = backend.drain(GB)
        r = threading.Thread(target=backend_reads)
        r.start()
        if pending:
            c.sendall(pending); 
        for chunk in chunks:
            sent_hash.update(chunk)
            c.sendall(chunk)
        c.shutdown(socket.SHUT_WR)
        r.join(120)
        c.close()
        t.check(reader_result.get("n") == GB, f"RT-5c once the backend reads, all 1 GB arrives ({reader_result.get('n')} bytes)")
        t.check(backend.digest.hexdigest() == sent_hash.hexdigest(), "RT-5c the 1 GB arrives in order, checksum equal")
        t.check(server.alive() and not server.stderr, f"RT-5c the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

def rt5d():
    bport, pport = free_port(), free_port()
    backend = EchoBackend(bport, backlog=1024)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, buffers=4, stat_ms=100)
    try:
        server.start().wait_ready()
        def client(i):
            c = connect(pport, timeout=120)
            sent, got = hashlib.sha256(), hashlib.sha256()
            res = {}
            r = threading.Thread(target=lambda: res.__setitem__("n", read_all(c, got)))
            r.start()
            send_stream(c, 9000 + i, MB, sent)
            c.shutdown(socket.SHUT_WR)
            r.join(120)
            c.close()
            return res.get("n") == MB and sent.hexdigest() == got.hexdigest()
        results = run_threads([lambda i=i: client(i) for i in range(100)])
        ok = sum(1 for r in results if r is True)
        t.check(ok == 100, f"RT-5d 100 echo clients x 1 MB through a 4-buffer pool all finish intact ({ok}/100)")
        waits = server.wait_stat("buffer_waits", lambda v: v > 0, timeout=3)
        t.note(f"RT-5d measured: buffer_waits={waits}, max buffers_in_use={server.max_buffers_in_use} of 4")
        t.check(waits > 0, f"RT-5d the pool really ran dry: reads had to wait (buffer_waits={waits})")
        t.check(server.max_buffers_in_use <= 4, f"RT-5d buffers_in_use never exceeded the pool of 4 (max {server.max_buffers_in_use})")
        t.check(server.alive() and not server.stderr, f"RT-5d the worker did not abort ({server.stderr[:2]})")
        # A client that connects after the storm is served: buffers came back.
        c = connect(pport, timeout=10); c.sendall(b"after"); got = recv_exact(c, 5); c.close()
        t.check(got == b"after", "RT-5d a client that connects afterwards is served")
    finally:
        server.stop(); backend.stop()

t.run(rt5c)
t.run(rt5d)
t.finish()
