#!/usr/bin/env python3
# Proves: RT-19a RT-19b RT-19c RT-19d RT-19e RT-19f   (handler edge cases from the review of 2026-11-14)
#   a  closing a connection that waits for a read buffer does not spend the freed buffer on itself (others waiting for a buffer are woken)
#   b  a send refused for lack of pool buffers (empty output queue) is followed by Writable when buffers come back; a send that can never fit promises none
#   c  bytes the socket takes while the queue drains count as activity (idle timeout)
#   d  forward() is refused after shutdown_write and after the peer's EOF
#   e  a dial in progress is ended by its own connect timeout, never by the idle timeout
#
#     tests/run_tests.sh handler_edges      (builds harness/edges_server.goose and sets EDGES_SERVER)
import os, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("handler_edges_test", "RT-19a RT-19b RT-19c RT-19d RT-19e RT-19f")
host_lock()
SERVER = os.environ.get("EDGES_SERVER", "tests/net/harness/edges_server")

class Run:
    def __init__(self, *flags):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}", *flags], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if "READY" in self.lines: break
            time.sleep(0.05)
        time.sleep(0.15)
    def conn(self, name, rcvbuf=None):
        s = socket.socket()
        if rcvbuf: s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        s.connect(("127.0.0.1", self.port))
        s.sendall(f"NAME {name}\n".encode())
        return s
    def has(self, prefix, since=0): return any(l.startswith(prefix) for l in self.lines[since:])
    def wait_for(self, prefix, secs, since=0):
        end = time.time() + secs
        while time.time() < end:
            if self.has(prefix, since): return True
            time.sleep(0.02)
        return False
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def drain(s, quiet=0.3):
    s.settimeout(quiet); n = 0
    try:
        while True:
            d = s.recv(1 << 20)
            if not d: break
            n += len(d)
    except (socket.timeout, OSError): pass
    return n

def body():
    # RT-19a: the buffer freed by a closing connection goes to the next reader, not to the closing connection itself
    r = Run("--buffers", "4", "--buffer-size", "4096")
    try:
        c, a, b, d = r.conn("c", rcvbuf=2048), r.conn("a", rcvbuf=2048), r.conn("b"), r.conn("d", rcvbuf=2048)   # small receive windows: the senders' queues stay full
        time.sleep(0.3)
        a.sendall(b"DO HOLD c 2\nDO HOLD a 1\nDO HOLD d 1\n")
        time.sleep(0.5)                                              # the Tick runs the script: the pool is now full (c holds 2, a 1, d 1), nobody can read
        m = len(r.lines)
        a.sendall(b"x"); time.sleep(0.3); b.sendall(b"y"); time.sleep(0.3)   # a waits for a buffer first, then b
        t.check(not r.has("DATA", m), f"RT-19a setup: with the pool full, neither read is delivered ({r.lines[m:]})")
        a.close()                                                    # a has unread bytes: the close is an RST, the engine closes a and frees its one queued buffer
        got = r.wait_for("DATA b", 1.5, m)
        t.check(r.has("CLOSED a", m), f"RT-19a a is closed ({r.lines[m:]})")
        t.check(got, f"RT-19a the buffer a gave back wakes b, who was waiting after it: b's byte is delivered ({r.lines[m:]})")
        for s in (b, c, d): s.close()
    finally: r.stop()

    # RT-19b: a refused send is followed by Writable when buffers return; a send that can never fit does not promise one
    r = Run("--buffers", "3", "--buffer-size", "4096")
    try:
        c, y, d = r.conn("c", rcvbuf=2048), r.conn("b"), r.conn("d", rcvbuf=2048)
        time.sleep(0.3)
        y.sendall(b"DO HOLD c 2\nDO HOLD d 1\nDO SEND b\n")
        r.wait_for("SEND b", 2)
        t.check(r.has("SEND b false"), f"RT-19b setup: with the pool full the send to b is refused ({r.lines})")
        m = len(r.lines)
        drain(c, 0.5)                                               # c's queued buffers go back to the pool
        got = r.wait_for("RETRY b true", 2, m)
        y.settimeout(1)
        try: pong = y.recv(10)
        except OSError: pong = b""
        t.check(got and pong == b"pong", f"RT-19b buffers returned: b gets Writable, the retry works and b receives the bytes ({r.lines[m:]}, {pong!r})")
        for s in (c, y, d): s.close()
    finally: r.stop()
    r = Run("--buffers", "64", "--buffer-size", "4096")
    try:
        e = r.conn("e")
        time.sleep(0.3)
        e.sendall(b"DO SENDBIG e\nDO SEND e\n")
        r.wait_for("SEND e", 2)
        time.sleep(0.5)
        t.check(r.has("SENDBIG e false") and r.has("SEND e true") and not r.has("WRITABLE"),
                f"RT-19b a send larger than the 4-buffer queue is refused and promises no Writable (none arrives after the next send) ({r.lines})")
        e.close()
    finally: r.stop()

    # RT-19c: bytes the socket takes while the queue drains count as activity
    r = Run("--buffers", "64", "--buffer-size", "4096", "--idle-ms", "800")
    try:
        x = r.conn("e", rcvbuf=2048)
        time.sleep(0.3)
        x.sendall(b"DO HOLD e 2\n")
        time.sleep(0.4)
        total = 0; end = time.time() + 3.0
        x.settimeout(0.05)
        while time.time() < end:
            try:
                d = x.recv(1024); total += len(d)
                if not d: break
            except socket.timeout: pass
            except OSError: break
            time.sleep(0.05)
        t.check(not r.has("CLOSED e"), f"RT-19c a peer that keeps reading slowly (3 s, idle timeout 0.8 s) is not closed as idle ({r.lines[-3:]}, read {total} bytes)")
        stopped = time.time()
        got = r.wait_for("CLOSED e", 3)
        t.check(got and "IdleTimeout" in " ".join(l for l in r.lines if l.startswith("CLOSED e")), f"RT-19c once it stops reading the idle timeout does end it ({[l for l in r.lines if l.startswith('CLOSED')]})")
        x.close()
    finally: r.stop()

    # RT-19d: forward is refused after shutdown_write and after the peer's EOF (the victim connections are unnamed: a NAME line would be a consumed byte)
    r = Run()
    try:
        g = r.conn("g"); time.sleep(0.2)
        v1 = socket.create_connection(("127.0.0.1", r.port)); time.sleep(0.3)
        g.sendall(b"DO SHUTFWD\n"); r.wait_for("FWD_AFTER_SHUT", 2)
        v2 = socket.create_connection(("127.0.0.1", r.port)); time.sleep(0.3)
        g.sendall(b"DO FWDONEOF\n"); time.sleep(0.4)
        v2.shutdown(socket.SHUT_WR)
        r.wait_for("FWD_ON_EOF", 2)
        t.check(r.has("FWD_AFTER_SHUT false"), f"RT-19d forward after shutdown_write is refused ({[l for l in r.lines if 'FWD' in l]})")
        t.check(r.has("FWD_ON_EOF false"), f"RT-19d forward after the peer's EOF is refused ({[l for l in r.lines if 'FWD' in l]})")
        for s_ in (g, v1, v2): s_.close()
    finally: r.stop()

    # RT-19f: a failed connect with no address left to try is not counted as a retry (a slot cleared by SetAddr is not an address)
    r = Run()
    try:
        g = r.conn("g"); time.sleep(0.2)
        v = socket.create_connection(("127.0.0.1", r.port)); time.sleep(0.3)
        g.sendall(b"DO FWDHOLE\n")
        r.wait_for("FWDHOLE", 2); time.sleep(0.6)
        g.sendall(b"DO STATS\n")
        got = r.wait_for("STATS", 2)
        line = [l for l in r.lines if l.startswith("STATS")]
        t.check(got and line[0] == "STATS retries=0" and r.has("FWDHOLE true"), f"RT-19f one refused address and one cleared slot: the failure is not a retry ({line}, {[l for l in r.lines if 'FWDHOLE' in l]})")
        g.close(); v.close()
    finally: r.stop()

    # RT-19e: a dial that is still connecting is ended by its own connect timeout, not by the idle timeout
    hole_port = free_port()
    hole = BlackholeBackend(hole_port)
    r = Run("--idle-ms", "1000")
    try:
        g = r.conn("g")
        time.sleep(0.3)
        start = time.time()
        g.sendall(f"DO DIAL 127.0.0.1:{hole_port} 3000\n".encode())
        got = r.wait_for("CLOSED #", 6)
        took = time.time() - start
        line = [l for l in r.lines if l.startswith("CLOSED #")]
        t.check(got and "ConnectFailed" in line[0] and 2.5 < took < 4.5, f"RT-19e a dial with connect_ms 3000 and idle timeout 1000 ends as ConnectFailed after about 3 s ({line}, {took:.1f} s)")
        g.close()
    finally:
        r.stop(); hole.stop()

t.run(body)
t.finish()
