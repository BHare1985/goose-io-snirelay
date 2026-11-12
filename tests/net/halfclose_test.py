#!/usr/bin/env python3
# Proves: RT-15a RT-15b RT-15c RT-15d RT-15e RT-15f RT-15g   (graceful close of handler connections: the peer's EOF with output still to send, shutdown_write, send_room)
#
#     tests/run_tests.sh halfclose      (builds harness/halfclose_server.goose and sets HALFCLOSE_SERVER)
import os, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("halfclose_test", "RT-15a RT-15b RT-15c RT-15d RT-15e RT-15f RT-15g")
host_lock()
SERVER = os.environ.get("HALFCLOSE_SERVER", "tests/net/harness/halfclose_server")

def pattern(n):
    return ((bytes(range(251)) * (n // 251 + 2))[:n])

class Run:
    def __init__(self):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if "READY" in self.lines: break
            time.sleep(0.05)
    def say(self, text): self.p.stdin.write(text + "\n"); self.p.stdin.flush()
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
        t.check(fresh == 131072 and 0 < after <= fresh, f"RT-15d send_room on a fresh connection is the whole queue (131072) and does not grow after a send ({fresh}, {after}); the socket takes 1000 bytes at once, so the room shrinks only for bytes that had to be queued")
        t.check(0 <= full < 16384, f"RT-15d when the queue is full the room is below one piece ({full})")
        read_all(c, secs=3)
        r.wait(lambda: any(l.startswith("ROOM after_drain") for l in r.lines[before:]))
        drained = [l for l in r.lines[before:] if l.startswith("ROOM after_drain")]
        t.check(bool(drained) and int(drained[0].split("=")[1]) > 0, f"RT-15d after the client reads, Writable comes and the room is back ({drained})")
        # RT-15g: ordering, and send after shutdown_write
        before = len(r.lines)
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /3000000 HTT"); time.sleep(0.2); c.sendall(b"P/1.1\r\n\r\n"); c.shutdown(socket.SHUT_WR)
        time.sleep(0.3)                                              # the EOF is read while the answer is still being produced
        read_all(c, secs=15); c.close()
        r.wait(lambda: any(l.startswith("CLOSED") for l in r.lines[before:]))
        seq = [l.split()[0] if not l.startswith("EV") else "DATA" for l in r.lines[before:] if l.startswith(("EV", "PEER_EOF", "CLOSED"))]
        t.check(seq and seq[-1] == "CLOSED" and seq.count("CLOSED") == 1 and seq.count("PEER_EOF") == 1 and seq.index("PEER_EOF") > max(i for i, x in enumerate(seq) if x == "DATA"),
                f"RT-15g PeerEof comes after every Data, Closed is last and exactly once ({seq})")
        t.check("SEND_AFTER_SHUTDOWN false" in r.lines[before:], f"RT-15g send after shutdown_write returns false ({[l for l in r.lines[before:] if l.startswith('SEND_AFTER')]})")
        # RT-15f: a kept-open connection whose handler never finishes is bounded by the half-close timeout (1 s in this harness)
        before = len(r.lines)
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /hang HTTP/1.1\r\n\r\n"); c.shutdown(socket.SHUT_WR)
        t0 = time.time()
        c.settimeout(6)
        try: ended = c.recv(10) == b""
        except OSError: ended = True
        took = time.time() - t0
        closed = [l for l in r.lines[before:] if l.startswith("CLOSED")]
        r.wait(lambda: any(l.startswith("CLOSED") for l in r.lines[before:]))
        closed = [l for l in r.lines[before:] if l.startswith("CLOSED")]
        t.check(ended and 0.9 <= took <= 2.0 and closed and "HalfCloseTimeout" in closed[0], f"RT-15f a kept-open connection whose handler never finishes is closed by the half-close timeout after {took:.2f} s ({closed})")
        # RT-15e: fencing beats half-close: a tag deadline expiring while the handler is still sending after PeerEof closes it as Fenced, zero bytes after
        before = len(r.lines)
        c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
        c.sendall(b"GET /trickle HTTP/1.1\r\n\r\n"); c.shutdown(socket.SHUT_WR)
        until = boottime_ms() + 700
        r.say(f"deadline 7 {until}")
        arrivals = []
        c.settimeout(5)
        while True:
            try: d = c.recv(100)
            except OSError: break
            if not d: break
            arrivals.append((boottime_ms(), len(d)))
        late = sum(n for at, n in arrivals if at > until + 100)
        r.wait(lambda: any(l.startswith("CLOSED") for l in r.lines[before:]))
        closed = [l for l in r.lines[before:] if l.startswith("CLOSED")]
        t.check(late == 0 and arrivals and closed and "Fenced" in closed[0], f"RT-15e a kept-open connection still sending after PeerEof is closed as Fenced at its deadline: {sum(n for _, n in arrivals)} bytes before, {late} after ({closed})")
        t.check(r.p.poll() is None, "the program is up")
    finally:
        r.stop()

t.run(body)
t.finish()
