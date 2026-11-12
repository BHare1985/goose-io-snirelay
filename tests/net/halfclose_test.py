#!/usr/bin/env python3
# Proves: RT-15a RT-15b RT-15c RT-15d   (graceful close of handler connections: the peer's EOF with output still to send, shutdown_write, send_room)
#
#     tests/run_tests.sh halfclose      (builds harness/halfclose_server.goose and sets HALFCLOSE_SERVER)
import os, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("halfclose_test", "RT-15a RT-15b RT-15c RT-15d")
host_lock()
SERVER = os.environ.get("HALFCLOSE_SERVER", "tests/net/harness/halfclose_server")

def pattern(n):
    return ((bytes(range(251)) * (n // 251 + 2))[:n])

class Run:
    def __init__(self):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if "READY" in self.lines: break
            time.sleep(0.05)
    def wait(self, pred, secs=4):
        end = time.time() + secs
        while time.time() < end:
            if pred(): return True
            time.sleep(0.02)
        return False
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def read_all(c, secs=15):
    c.settimeout(secs)
    got = b""
    try:
        while (d := c.recv(1 << 20)): got += d
    except OSError:
        pass
    return got

def body():
    r = Run()
    try:
        # RT-15a: the client sends its request and shuts down its sending side at once; the whole response still arrives, then EOF
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /3000000 HTTP/1.1\r\n\r\n"); c.shutdown(socket.SHUT_WR)
        time.sleep(0.5)                                              # the server reads the EOF while most of the response is still to be sent
        got = read_all(c)
        t.check(got == pattern(3000000), f"RT-15a request + immediate shutdown(WR): all 3,000,000 bytes arrive in order, then EOF ({len(got)} bytes)")
        t.check(r.wait(lambda: r.lines.count("PEER_EOF") == 1), f"RT-15a PeerEof delivered once to a connection that opted in ({r.lines.count('PEER_EOF')})")
        t.check(r.wait(lambda: any(l.startswith("CLOSED") for l in r.lines)), "RT-15a and the connection then closes (Closed delivered)")
        # RT-15b: a connection that did not opt in keeps the old behaviour: a small answer is flushed, then the connection closes
        before = len(r.lines)
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /plain/20000 HTTP/1.1\r\n\r\n"); c.shutdown(socket.SHUT_WR)
        got = read_all(c)
        t.check(got == pattern(20000), f"RT-15b without the opt-in the queued answer is flushed and the connection closes ({len(got)} bytes)")
        t.check(not any(l == "PEER_EOF" for l in r.lines[before:]), "RT-15b and no PeerEof event for it")
        # RT-15c: shutdown_write after the queue drained: the client sees its bytes, then a clean EOF while it can still send
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /40000 HTTP/1.1\r\n\r\n")
        got = read_all(c, secs=5)
        t.check(got == pattern(40000), f"RT-15c shutdown_write: the client reads 40,000 bytes then EOF without the server closing first ({len(got)} bytes)")
        try: c.sendall(b"x"); sent_after = True
        except OSError: sent_after = False
        t.check(sent_after, "RT-15c and the client can still send after the server's shutdown_write (half-closed, not closed)")
        c.close()
        # RT-15d: send_room
        before = len(r.lines)
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /room HTTP/1.1\r\n\r\n")
        time.sleep(1.0)                                              # the client reads nothing: the queue fills
        r.wait(lambda: any(l.startswith("ROOM fresh") for l in r.lines[before:]))
        first = [l for l in r.lines[before:] if l.startswith("ROOM fresh")]
        fresh = after = full = -1
        if first:
            kv = dict(x.split("=") for x in first[0].split()[1:])
            fresh, after, full = int(kv["fresh"]), int(kv["after1000"]), int(kv["full"])
        t.check(fresh == 131072 and after == 131072 - 1000, f"RT-15d send_room on a fresh connection is the whole queue (131072) and shrinks by what was sent ({fresh}, {after})")
        t.check(0 <= full < 16384, f"RT-15d when the queue is full the room is below one piece ({full})")
        read_all(c, secs=3)
        r.wait(lambda: any(l.startswith("ROOM after_drain") for l in r.lines[before:]))
        drained = [l for l in r.lines[before:] if l.startswith("ROOM after_drain")]
        t.check(bool(drained) and int(drained[0].split("=")[1]) > 0, f"RT-15d after the client reads, Writable comes and the room is back ({drained})")
        t.check(r.p.poll() is None, "the program is up")
    finally:
        r.stop()

t.run(body)
t.finish()
