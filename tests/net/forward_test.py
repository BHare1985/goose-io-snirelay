#!/usr/bin/env python3
# Proves: RT-4a RT-4b   (exact forwarding both ways under load; half-close both ways, close, reset)
#
#     tests/net/forward_test.py
#
# One worker, plain forwarding, independent Python clients and backends. Payloads are deterministic
# pseudo-random streams (netlib.stream), so every transfer is checked by SHA-256 without holding it in memory.
import hashlib, os, socket, struct, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("forward_test", "RT-4a RT-4b")
host_lock()

MB = 1 << 20
CLIENTS = 64
SIZE = 10 * MB

def with_proxy(fn, **server_kw):
    """Starts a backend (made by fn(port) -> backend) and the proxy in front of it; returns (proxy_port, backend, server)."""
    bport, pport = free_port(), free_port()
    backend = fn(bport)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, **server_kw)
    server.start().wait_ready()
    return pport, backend, server

# ---------------------------------------------------------------------------------------- RT-4a

def rt4a_echo():
    pport, backend, server = with_proxy(lambda p: EchoBackend(p))
    try:
        def client(i):
            c = connect(pport, timeout=120)
            sent, got = hashlib.sha256(), hashlib.sha256()
            result = {}
            def reader():
                result["n"] = read_all(c, got)
            r = threading.Thread(target=reader)
            r.start()
            send_stream(c, 1000 + i, SIZE, sent)
            c.shutdown(socket.SHUT_WR)
            r.join(120)
            c.close()
            return sent.hexdigest() == got.hexdigest() and result.get("n") == SIZE

        t0 = time.time()
        results = run_threads([lambda i=i: client(i) for i in range(CLIENTS)])
        ok = sum(1 for r in results if r is True)
        t.check(ok == CLIENTS, f"RT-4a echo: {CLIENTS} clients x 10 MB come back byte-exact ({ok}/{CLIENTS}, {time.time()-t0:.1f}s)")
        total = CLIENTS * SIZE
        bin_ = server.wait_stat("bytes_in", lambda v: v >= total, timeout=4)
        bout = server.wait_stat("bytes_out", lambda v: v >= total, timeout=4)
        t.check(bin_ == total and bout == total, f"RT-4a the worker counted {total} bytes each way (in {bin_}, out {bout})")
        t.check(server.alive() and not server.stderr, f"RT-4a the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

def rt4a_sink_and_source():
    # client -> backend: the backend hashes what it receives, keyed by the client id sent first.
    got = {}
    lock = threading.Lock()
    def sink(c):
        cid = struct.unpack(">I", recv_exact(c, 4))[0]
        h = hashlib.sha256()
        n = read_all(c, h)
        with lock:
            got[cid] = (n, h.hexdigest())
        c.sendall(b"ok")
        return cid
    # backend -> client: the backend sends 10 MB seeded by the client id.
    def source(c):
        cid = struct.unpack(">I", recv_exact(c, 4))[0]
        send_stream(c, 5000 + cid, SIZE)
        c.shutdown(socket.SHUT_WR)
        read_all(c)
        return cid
    for name, handler, direction in [("client to backend", sink, "up"), ("backend to client", source, "down")]:
        bport, pport = free_port(), free_port()
        backend = ThreadedBackend(bport, handler)
        server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1).start().wait_ready()
        try:
            def client(i):
                c = connect(pport, timeout=120)
                c.sendall(struct.pack(">I", i))
                if direction == "up":
                    sent = hashlib.sha256()
                    send_stream(c, 3000 + i, SIZE, sent)
                    c.shutdown(socket.SHUT_WR)
                    ack = read_all(c)
                    c.close()
                    return ack == 2 and sent.hexdigest()
                else:
                    h = hashlib.sha256()
                    n = read_all(c, h)
                    c.shutdown(socket.SHUT_WR)
                    c.close()
                    return n == SIZE and h.hexdigest() == digest(5000 + i, SIZE)
            results = run_threads([lambda i=i: client(i) for i in range(CLIENTS)])
            if direction == "up":
                ok = sum(1 for i, r in enumerate(results)
                         if isinstance(r, str) and got.get(i) == (SIZE, r))
            else:
                ok = sum(1 for r in results if r is True)
            t.check(ok == CLIENTS, f"RT-4a {name}: {CLIENTS} x 10 MB arrive byte-exact ({ok}/{CLIENTS})")
        finally:
            server.stop(); backend.stop()

# ---------------------------------------------------------------------------------------- RT-4b

def rt4b_client_half_close(delay):
    seen = {}
    def backend_handler(c):
        h = hashlib.sha256()
        n = read_all(c, h)                      # returns only when the client's FIN arrives
        seen["eof_after"] = n
        seen["sha"] = h.hexdigest()
        if delay: time.sleep(delay)
        send_stream(c, 77, 2 * MB)
        return n                                 # the thread closes the socket
    bport, pport = free_port(), free_port()
    backend = ThreadedBackend(bport, backend_handler)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1).start().wait_ready()
    try:
        c = connect(pport, timeout=30)
        sent = hashlib.sha256()
        send_stream(c, 76, MB, sent)
        c.shutdown(socket.SHUT_WR)               # half-close: "I am done sending"
        h = hashlib.sha256()
        n = read_all(c, h)                       # the reply must still arrive, then EOF
        label = f"client half-close{' with a reply delayed %.1fs' % delay if delay else ''}"
        t.check(n == 2 * MB and h.hexdigest() == digest(77, 2 * MB), f"RT-4b {label}: the 2 MB reply arrives intact, then EOF ({n} bytes)")
        backend.wait_results(1)
        t.check(seen.get("eof_after") == MB and seen.get("sha") == sent.hexdigest(),
                f"RT-4b {label}: the backend saw all 1 MB and then EOF (got {seen.get('eof_after')})")
        c.close()
    finally:
        server.stop(); backend.stop()

def rt4b_backend_half_close():
    seen = {}
    def backend_handler(c):
        send_stream(c, 91, MB)
        c.shutdown(socket.SHUT_WR)               # the backend is done sending but still listens
        h = hashlib.sha256()
        n = read_all(c, h)                       # the client's later 2 MB must still reach us
        seen["n"], seen["sha"] = n, h.hexdigest()
        return n
    bport, pport = free_port(), free_port()
    backend = ThreadedBackend(bport, backend_handler)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1).start().wait_ready()
    try:
        c = connect(pport, timeout=30)
        h = hashlib.sha256()
        n = read_all(c, h)                       # EOF arrives after the backend's 1 MB
        t.check(n == MB and h.hexdigest() == digest(91, MB), f"RT-4b backend half-close: the client gets the 1 MB then EOF ({n} bytes)")
        sent = hashlib.sha256()
        send_stream(c, 92, 2 * MB, sent)         # the client side must still be writable
        c.shutdown(socket.SHUT_WR)
        backend.wait_results(1)
        t.check(seen.get("n") == 2 * MB and seen.get("sha") == sent.hexdigest(),
                f"RT-4b backend half-close: the client's later 2 MB reaches the backend ({seen.get('n')} bytes)")
        c.close()
    finally:
        server.stop(); backend.stop()

def rt4b_both_close_and_reset():
    state = {"mode": None}
    def backend_handler(c):
        mode = state["mode"]
        if mode == "both":
            c.sendall(b"x" * 100_000)
            c.close()
            return "closed"
        if mode == "backend_rst":
            c.recv(10)                           # the client has sent something
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            c.close()                            # RST
            return "rst"
        if mode == "client_rst":
            try:
                c.settimeout(5)
                while c.recv(65536):
                    pass
                return "eof"
            except ConnectionResetError:
                return "reset"
            except socket.timeout:
                return "hung"
    bport, pport = free_port(), free_port()
    backend = ThreadedBackend(bport, backend_handler)
    server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1).start().wait_ready()
    try:
        # Both sides close at once: nothing hangs, nothing stays open.
        state["mode"] = "both"
        c = connect(pport, timeout=10)
        c.sendall(b"y" * 100_000)
        c.close()
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=3) == 0, "RT-4b both sides close at once: no connection stays open")
        backend.wait_results(1, timeout=3)           # that connection's handler must finish before the next scenario

        # The client resets (RST) in the middle of a transfer: the backend side is torn down within 1 s.
        state["mode"] = "client_rst"
        backend.results.clear()
        c = connect(pport, timeout=10)
        c.sendall(b"z" * 10_000)
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        t0 = time.time()
        c.close()
        r = backend.wait_results(1, timeout=3)
        t.check(r and r[0] in ("eof", "reset") and time.time() - t0 < 1.5, f"RT-4b client RST: the backend side is closed within 1 s ({r}, {time.time()-t0:.2f}s)")
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=3) == 0, "RT-4b client RST: no connection stays open")

        # The backend resets: the client sees the connection end within 1 s.
        state["mode"] = "backend_rst"
        backend.results.clear()
        c = connect(pport, timeout=10)
        c.sendall(b"hello")
        c.settimeout(3)
        t0 = time.time()
        try:
            data = c.recv(100)
            ended = data == b""
        except ConnectionResetError:
            ended = True
        except socket.timeout:
            ended = False
        t.check(ended and time.time() - t0 < 1.5, f"RT-4b backend RST: the client sees the end within 1 s ({time.time()-t0:.2f}s)")
        c.close()
        t.check(server.wait_stat("open", lambda v: v == 0, timeout=3) == 0, "RT-4b backend RST: no connection stays open")

        # The worker survived all of it: a fresh connection still works.
        state["mode"] = "both"
        c = connect(pport, timeout=10)
        d = c.recv(100_000)
        t.check(server.alive() and len(d) > 0, "RT-4b the worker is still serving after resets and closes")
        c.close()
        t.check(not server.stderr, f"RT-4b the worker wrote nothing to stderr ({server.stderr[:2]})")
    finally:
        server.stop(); backend.stop()

t.run(rt4a_echo)
t.run(rt4a_sink_and_source)
t.run(lambda: rt4b_client_half_close(0))
t.run(lambda: rt4b_client_half_close(0.5))
t.run(rt4b_backend_half_close)
t.run(rt4b_both_close_and_reset)
t.finish()
