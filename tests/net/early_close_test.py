#!/usr/bin/env python3
# Proves: RT-21a RT-21b RT-21c RT-21d   (a TLS session whose server ends before its first byte is retried on the next address with the
#                                         same hello; not after a byte; not on a plain listener; the counter says so)
#
#     tests/net/early_close_test.py
#
# Two backends behind one route (the built-in rotation: the first connection starts at A, the second address is B).
# Backend A reads what the proxy sent, then does what the case says: close with no byte, reset with no byte, or send one byte and close.
# Backend B answers "B" once it has the whole hello and then records what it got. The hello is a real capture (tests/data).
import os, socket, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
HELLO = open(os.path.join(DATA, "s1_openssl.bin"), "rb").read()
t = Test("early_close_test", "RT-21a RT-21b RT-21c RT-21d")
host_lock()

def read_hello(c):
    c.settimeout(3)
    got = b""
    while len(got) < len(HELLO):
        d = c.recv(65536)
        if not d:
            break
        got += d
    return got

def backend_a(mode):
    def handler(c):
        got = read_hello(c)
        if mode == "byte":
            c.sendall(b"A")
        if mode == "rst":
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        return ("A", got)
    return handler

def backend_b(c):
    got = read_hello(c)
    c.sendall(b"B")
    c.settimeout(1)
    try:
        while c.recv(65536):
            pass
    except (socket.timeout, ConnectionResetError):
        pass
    return ("B", got)

class Rig:
    def __init__(self, mode, sni):
        self.pa, self.pb, self.port = free_port(), free_port(), free_port()
        self.a = ThreadedBackend(self.pa, backend_a(mode))
        self.b = ThreadedBackend(self.pb, backend_b)
        to = f"127.0.0.1:{self.pa},127.0.0.1:{self.pb}"
        if sni:
            self.server = Server([], [], workers=1, stat_ms=200, nofile=4096,
                                 extra=["--inspect-listen", f"127.0.0.1:{self.port}", "--sni-any", to])
        else:
            self.server = Server([], [], workers=1, stat_ms=200, nofile=4096, routes=[(f"127.0.0.1:{self.port}", to.split(","))])
        self.server.start().wait_ready()

    def session(self):
        """One client: sends the hello, reads until the proxy ends it. Returns the bytes the client saw."""
        c = connect(self.port, timeout=10)
        c.sendall(HELLO)
        c.settimeout(4)
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
        time.sleep(0.3)
        return seen

    def got(self):
        return ([r[1] for r in self.a.results], [r[1] for r in self.b.results])

    def stop(self):
        self.server.stop(); self.a.stop(); self.b.stop()

def retried(mode, row):
    rig = Rig(mode, sni=True)
    try:
        seen = rig.session()
        a, b = rig.got()
        t.check(seen == b"B", f"{row} A ends with no byte ({mode}): the client is answered by B (saw {seen!r})")
        t.check(a == [HELLO] and b == [HELLO], f"{row} A and B each got the whole hello from byte 0 (A {[len(x) for x in a]}, B {[len(x) for x in b]} of {len(HELLO)})")
        t.check(rig.server.wait_stat("retries", lambda v: v >= 1, timeout=3) >= 1, "RT-21d the retry is counted in the worker's retries")
    finally:
        rig.stop()

def not_after_a_byte():
    rig = Rig("byte", sni=True)
    try:
        seen = rig.session()
        a, b = rig.got()
        t.check(seen == b"A" and not b, f"RT-21b A sent one byte and then closed: no retry, B is not contacted (saw {seen!r}, B got {b})")
    finally:
        rig.stop()

def not_on_plain():
    rig = Rig("close", sni=False)
    try:
        seen = rig.session()
        a, b = rig.got()
        t.check(seen == b"" and not b, f"RT-21c a plain listener never replays the client's bytes: closed, B not contacted (saw {seen!r}, B got {b})")
    finally:
        rig.stop()

t.run(lambda: retried("close", "RT-21a"))
t.run(lambda: retried("rst", "RT-21a"))
t.run(not_after_a_byte)
t.run(not_on_plain)
t.finish()
