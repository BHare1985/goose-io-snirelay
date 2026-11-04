#!/usr/bin/env python3
# Proves: RT-3c RT-3d RT-3f RT-3g   (engine halves: routing on the ClientHello without consuming it; inspect timeout;
#                                    an oversize hello is closed not buffered; a non-TLS client is routed at its first byte)
#
#     tests/net/sni_forward_test.py
#
# One listener with `inspect: Sni` and routes: seven names to backend A, "no name or not TLS" to backend C, everything else
# to backend B. Every backend sends its one-letter name as soon as it is connected to, then records every byte it receives
# until the client half-closes, so the test can tell WHICH backend got a connection and EXACTLY what it got.
# The ClientHellos are the real captures in tests/data/ (README.md there lists who sent them).
import os, socket, struct, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
t = Test("sni_forward_test", "RT-3c RT-3d RT-3f RT-3g")
host_lock()

# name each capture is expected to carry, and where the routes send it
ROUTED = {  # file -> name (all routed to A)
    "s1_openssl.bin": "api.example.com",
    "s2_openssl_upper_dot.bin": "api.example.com",          # sent as "API.Example.COM." (lowercased, dot dropped)
    "s12_curl_http1.bin": "curl.example.com",
    "s12_curl_h2.bin": "curlh2.example.com",
    "s12_python.bin": "python.example.com",
    "s12_wget_localhost.bin": "localhost",
    "s12_openssl_tls12.bin": "tls12.example.com",
    "s12_openssl_tls13_alpn.bin": "alpn.example.com",
}
UNROUTED = "s12_node.bin"           # node.example.com has no route: it falls to B
NO_NAME = "s3_openssl_nosni.bin"    # a valid hello without a name: C

def hello(name):
    return open(os.path.join(DATA, name), "rb").read()

def recorder(tag):
    def handler(c):
        c.sendall(tag)
        c.settimeout(4)
        data = b""
        try:
            while True:
                d = c.recv(65536)
                if not d:
                    break
                data += d
        except socket.timeout:
            pass
        return (tag, data)
    return handler

class Rig:
    def __init__(self, with_default=True, inspect_ms=None, extra=()):
        self.ports = {k: free_port() for k in "ABC"}
        self.backends = {k: ThreadedBackend(p, recorder(k.encode())) for k, p in self.ports.items()}
        self.port = free_port()
        args = ["--inspect-listen", f"127.0.0.1:{self.port}"]
        for name in sorted(set(ROUTED.values())):
            args += ["--sni", f"{name}=127.0.0.1:{self.ports['A']}"]
        args += ["--sni-none", f"127.0.0.1:{self.ports['C']}"]
        if with_default:
            args += ["--sni-any", f"127.0.0.1:{self.ports['B']}"]
        if inspect_ms:
            args += ["--inspect-timeout-ms", str(inspect_ms)]
        self.server = Server([], [], workers=1, stat_ms=200, nofile=4096, extra=args + list(extra))
        self.server.start().wait_ready()

    def exchange(self, payload, gap=0.0, close_after=True):
        """Sends payload (byte by byte with `gap` seconds between if gap), half-closes, returns (tag the client saw, {backend: bytes it got})."""
        before = {k: len(b.results) for k, b in self.backends.items()}
        c = connect(self.port, timeout=10)
        if gap:
            for i in range(len(payload)):
                c.sendall(payload[i:i + 1])
                time.sleep(gap)
        else:
            c.sendall(payload)
        c.shutdown(socket.SHUT_WR)
        seen = b""
        try:
            while True:
                d = c.recv(100)
                if not d:
                    break
                seen += d
        except (socket.timeout, ConnectionResetError):
            pass
        c.close()
        time.sleep(0.2)
        got = {k: [r[1] for r in b.results[before[k]:]] for k, b in self.backends.items()}
        return seen, got

    def stop(self):
        self.server.stop()
        for b in self.backends.values():
            b.stop()

# ----------------------------------------------------------------------------------------------- RT-3c

def rt3c():
    rig = Rig()
    try:
        extra = b"APPLICATION-DATA-AFTER-THE-HELLO"
        for f, name in ROUTED.items():
            payload = hello(f) + extra
            seen, got = rig.exchange(payload)
            ok = seen == b"A" and got["A"] == [payload] and not got["B"] and not got["C"]
            t.check(ok, f"RT-3c {f} ({name}) reaches backend A with every byte from byte 0 (client saw {seen!r}, A got {[len(x) for x in got['A']]} bytes of {len(payload)})")
        payload = hello(UNROUTED) + extra
        seen, got = rig.exchange(payload)
        t.check(seen == b"B" and got["B"] == [payload], "RT-3c a name with no route (node.example.com) falls to the Any route B, byte for byte")
        payload = hello(NO_NAME) + extra
        seen, got = rig.exchange(payload)
        t.check(seen == b"C" and got["C"] == [payload], "RT-3c a hello without a name takes the NoSni route C, byte for byte")
        # The hello arrives one byte at a time: routing waits for it, and nothing is lost.
        payload = hello("s1_openssl.bin")[:400] + b"" 
        full = hello("s1_openssl.bin") + extra
        seen, got = rig.exchange(full, gap=0.002)
        t.check(seen == b"A" and got["A"] == [full], f"RT-3c a hello dribbled one byte per 2 ms is routed when complete and arrives whole (A got {[len(x) for x in got['A']]} of {len(full)})")
        t.check(rig.server.alive() and not rig.server.stderr, f"RT-3c the worker is up and silent ({rig.server.stderr[:2]})")
    finally:
        rig.stop()

# ----------------------------------------------------------------------------------------------- RT-3d

def rt3d():
    rig = Rig(inspect_ms=1000)
    try:
        c = connect(rig.port, timeout=10)
        t0 = time.time()
        c.settimeout(4)
        try:
            d = c.recv(10)
            closed = d == b""
        except ConnectionResetError:
            closed = True
        took = time.time() - t0
        t.check(closed, "RT-3d a client that sends nothing is closed")
        t.check(0.9 <= took <= 1.3, f"RT-3d ... after the inspect timeout, not before and not much after ({took:.2f}s for 1.0s)")
        t.check(rig.server.wait_closed("InspectTimeout", lambda v: v == 1, timeout=3) == 1, f"RT-3d it is counted as closed by InspectTimeout ({rig.server.closed('InspectTimeout')})")
        # Part of a hello, then silence: the clock runs from the connection, not from the last byte.
        c = connect(rig.port, timeout=10)
        c.sendall(hello("s1_openssl.bin")[:100])
        t0 = time.time()
        c.settimeout(4)
        try:
            closed = c.recv(10) == b""
        except ConnectionResetError:
            closed = True
        took = time.time() - t0
        t.check(closed and took <= 1.3, f"RT-3d a hello that stops arriving is closed within the timeout ({took:.2f}s)")
        t.check(not any(b.results for b in rig.backends.values()), "RT-3d no backend was ever contacted for either")
    finally:
        rig.stop()

# ----------------------------------------------------------------------------------------------- RT-3f

def rt3f():
    rig = Rig(inspect_ms=5000)
    try:
        # A record that claims more than 16384 bytes is closed at once, from its header alone.
        c = connect(rig.port, timeout=10)
        c.sendall(b"\x16\x03\x01\x40\x01")
        t0 = time.time()
        c.settimeout(3)
        try:
            closed = c.recv(10) == b""
        except ConnectionResetError:
            closed = True
        took = time.time() - t0
        t.check(closed and took < 0.5, f"RT-3f a record header declaring 16385 bytes is closed at once ({took:.2f}s, the inspect timeout is 5 s)")
        t.check(rig.server.wait_closed("InvalidHello", lambda v: v == 1, timeout=3) == 1, f"RT-3f ... counted as InvalidHello ({rig.server.closed('InvalidHello')})")
        # A handshake that declares 20000 bytes in a small first record: also closed at once.
        c = connect(rig.port, timeout=10)
        c.sendall(b"\x16\x03\x01\x00\x20\x01\x00\x4e\x20" + b"\x00" * 27)
        c.settimeout(3)
        try:
            closed = c.recv(10) == b""
        except ConnectionResetError:
            closed = True
        t.check(closed, "RT-3f a handshake declaring 20000 bytes is closed at once")
        # Not buffered: 500 connections that each sent most of a valid hello cost the worker (almost) nothing.
        base = rig.server.rss_kb()
        part = hello("s1_openssl.bin")[:1200]
        held = []
        for i in range(500):
            c = connect(rig.port, timeout=10)
            c.sendall(part)
            held.append(c)
        rig.server.wait_stat("open", lambda v: v >= 500, timeout=5)
        time.sleep(0.5)
        grown = rig.server.rss_kb() - base
        t.note(f"RT-3f measured: RSS grew {grown} kB for 500 connections holding 1200 bytes of hello each (600 kB of data)")
        t.check(rig.server.total("open") >= 500, f"RT-3f the 500 half-sent hellos are waiting ({rig.server.total('open')} open)")
        t.check(grown < 1024, f"RT-3f the worker does not keep their bytes: RSS grew {grown} kB (limit 1024 kB; buffering would be >= 600 kB plus tables)")
        rest = hello("s1_openssl.bin")[1200:]
        for c in held:
            c.sendall(rest)
            c.shutdown(socket.SHUT_WR)
        done = 0
        for c in held:
            c.settimeout(10)
            try:
                if c.recv(1) == b"A":
                    done += 1
            except OSError:
                pass
            c.close()
        t.check(done == 500, f"RT-3f when the rest arrives, all 500 are routed to A ({done}/500)")
    finally:
        rig.stop()

# ----------------------------------------------------------------------------------------------- RT-3g

def rt3g():
    rig = Rig(inspect_ms=5000)
    try:
        c = connect(rig.port, timeout=10)
        c.sendall(b"G")                                   # one byte: enough to know it is not TLS
        t0 = time.time()
        c.settimeout(3)
        tag = c.recv(1)
        took = time.time() - t0
        t.check(tag == b"C" and took < 0.5, f"RT-3g one non-TLS byte is routed to the NoSni backend at once ({tag!r} after {took:.2f}s, inspect timeout 5 s)")
        c.sendall(b"ET / HTTP/1.1\r\nHost: x\r\n\r\n")
        c.shutdown(socket.SHUT_WR)
        c.settimeout(5)
        while c.recv(100):
            pass
        c.close()
        time.sleep(0.3)
        t.check(rig.backends["C"].results and rig.backends["C"].results[-1][1] == b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", "RT-3g the backend received the whole request from its first byte")
    finally:
        rig.stop()

def no_route():
    rig = Rig(with_default=False)
    try:
        seen, got = rig.exchange(hello(UNROUTED))
        t.check(seen == b"" and not any(got.values()), f"RT-3 with no Any route, an unmatched name is closed and no backend is contacted (saw {seen!r})")
    finally:
        rig.stop()

t.run(rt3c)
t.run(rt3d)
t.run(rt3f)
t.run(rt3g)
t.run(no_route)
t.finish()
