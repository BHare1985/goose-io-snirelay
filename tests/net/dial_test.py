#!/usr/bin/env python3
# Proves: RT-14a RT-14b RT-14c RT-14d RT-14e RT-14f RT-14g RT-14h RT-14i   (w.dial: outbound handler connections; spec: skein docs/dial-red-gate.md plus Milli's pipelining check)
#
#     tests/run_tests.sh dial      (builds harness/dial_server.goose and sets DIAL_SERVER)
import os, queue, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("dial_test", "RT-14a RT-14b RT-14c RT-14d RT-14e RT-14f RT-14g RT-14h RT-14i")
host_lock()
SERVER = os.environ.get("DIAL_SERVER", "tests/net/harness/dial_server")

class Run:
    def __init__(self, workers=1):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}", "--workers", str(workers), "--control"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if self.lines.count("READY") >= workers: break
            time.sleep(0.05)
    def say(self, text): self.p.stdin.write(text + "\n"); self.p.stdin.flush()
    def wait(self, pred, secs=3):
        end = time.time() + secs
        while time.time() < end:
            if pred(): return True
            time.sleep(0.02)
        return False
    def get(self, target, timeout=5):
        try: return self._get(target, timeout)
        except OSError: return None, 0, b""            # a hang or reset is a failed check, not a crashed test
    def _get(self, target, timeout):
        c = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        c.sendall(f"GET {target} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = c.recv(65536)
            if not d: return c, None, b""
            buf += d
        head, rest = buf.split(b"\r\n\r\n", 1)
        n = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
        while len(rest) < n:
            d = c.recv(65536)
            if not d: break
            rest += d
        c.close()
        return c, int(head.split()[1]), rest
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

class Echo:
    """A TCP server. delay: seconds before the first reply; stall: seconds it does not read at all; close_after_read: read and close without replying."""
    def __init__(self, delay=0.0, stall=0.0, close_after_read=False):
        self.port = free_port()
        self.delay, self.stall, self.close_after_read = delay, stall, close_after_read
        self.sock = socket.socket(); self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port)); self.sock.listen(256)
        self.received = []; self.accepts = 0
        threading.Thread(target=self.loop, daemon=True).start()
    def loop(self):
        while True:
            try: c, _ = self.sock.accept()
            except OSError: return
            self.accepts += 1
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()
    def serve(self, c):
        try:
            time.sleep(self.stall)
            first = True
            while (d := c.recv(65536)):
                self.received.append((boottime_ms(), len(d)))
                if self.close_after_read: break
                if first and self.delay: time.sleep(self.delay)
                first = False
                c.sendall(d)
        except OSError: pass
        c.close()
    def total(self): return sum(n for _, n in self.received)
    def stop(self): self.sock.close()

def hanging_listener():
    """A listener whose accept queue is full, so new connects hang (SYNs are dropped): a connect that never finishes."""
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(0)
    port = s.getsockname()[1]
    fillers = []
    for _ in range(3):
        f = socket.socket(); f.setblocking(False)
        try: f.connect(("127.0.0.1", port))
        except BlockingIOError: pass
        fillers.append(f)
    time.sleep(0.2)
    return s, fillers, port

def body():
    echo = Echo()
    r = Run(workers=1)
    try:
        t.check(r.lines.count("READY") == 1, "server started")
        # 1, 1b: one request through a dialled connection; send before Opened is false and queues nothing
        _, status, b = r.get(f"/via/{echo.port}")
        t.check(status == 200 and b == b"hello", f"RT-14a one request returns 'hello' through a dialled echo ({status}, {b!r})")
        t.check(r.wait(lambda: "DIAL send_before_open=false" in r.lines), f"RT-14b send() before Opened returns false ({[l for l in r.lines if l.startswith('DIAL ')][:2]})")
        t.check(echo.total() == 5, f"RT-14b and nothing was queued by it: the echo server received exactly the 5 bytes sent after Opened ({echo.total()})")
        # 3: closed port
        before = len(r.lines)
        _, status, b = r.get(f"/via/{free_port()}")
        t.check(status == 502, f"RT-14c dial to a closed port: the client gets 502 ({status})")
        r.wait(lambda: any("why=ConnectFailed" in l for l in r.lines[before:]))
        new = r.lines[before:]
        closed = [l for l in new if l.startswith("DIAL_CLOSED")]
        t.check(len(closed) == 1 and "why=ConnectFailed" in closed[0] and "opened=false" in closed[0] and not any(l.startswith("DIAL_OPENED") for l in new),
                f"RT-14c Closed(ConnectFailed) exactly once and no Opened before it ({closed})")
        # 4: a connect that hangs, with its own timeout
        hs, fillers, hport = hanging_listener()
        t0 = time.time()
        _, status, b = r.get(f"/via/{hport}/200")
        took = time.time() - t0
        t.check(status == 502 and 0.18 <= took <= 0.5, f"RT-14d a hanging connect with connect_ms=200 fails after {took:.2f} s (want 0.2 to 0.4, sweep slack 0.1) status {status}")
        hs.close()
        # 5: the peer closes mid-way
        dead = Echo(close_after_read=True)
        before = len(r.lines)
        _, status, b = r.get(f"/via/{dead.port}")
        r.wait(lambda: any(l.startswith("DIAL_CLOSED") for l in r.lines[before:]))
        closed = [l for l in r.lines[before:] if l.startswith("DIAL_CLOSED")]
        t.check(status == 502 and len(closed) == 1 and "opened=true" in closed[0], f"RT-14e the peer closed after Opened: one Closed, the client got 502 ({status}, {closed})")
        dead.stop()
        # 8 / Milli: pipelining on a dialled connection: 500 small sends back to back, in order
        _, status, b = r.get(f"/pipe/{echo.port}/500")
        t.check(status == 200 and b == b"OK falses=0", f"RT-14h 500 small sends queued back to back on a dialled connection are all accepted and echoed in order ({status}, {b!r})")
        # Milli: a stalled peer fills the queue (send says false), then Writable resumes it, bytes in order
        slow = Echo(stall=1.5)
        _, status, b = r.get(f"/pipeb/{slow.port}/6000", timeout=30)
        falses = int(b.split(b"falses=")[1]) if status == 200 and b.startswith(b"OK") else -1
        t.check(status == 200 and b.startswith(b"OK") and falses > 0, f"RT-14h a stalled peer fills the queue ({falses} refusals), Writable resumes it, 6 MB arrive in order ({status}, {b[:30]!r})")
        slow.stop()
        # 2: the worker is not blocked by a slow reply
        slowreply = Echo(delay=0.6)
        res = {}
        th = threading.Thread(target=lambda: res.update(r=r.get(f"/via/{slowreply.port}")[1:]))
        th.start(); time.sleep(0.1)
        worst = 0.0
        for _ in range(50):
            t0 = time.time(); _, st, _ = r.get("/fast"); worst = max(worst, time.time() - t0)
            if st != 200: break
        th.join()
        t.check(worst < 0.05 and res.get("r", (0,))[0] == 200, f"RT-14f while a dialled reply is 600 ms away, 50 other requests are answered (worst {worst * 1000:.0f} ms, want < 50)")
        slowreply.stop()
        # 7: a tag whose deadline passes
        rec = Echo()
        until = boottime_ms() + 700
        r.say(f"deadline 9 {until}")
        time.sleep(0.2)
        before = len(r.lines)
        _, status, b = r.get(f"/fence/{rec.port}")
        time.sleep(1.2)
        late = sum(n for at, n in rec.received if at > until + 100)
        early = sum(n for at, n in rec.received if at <= until)
        fenced = [l for l in r.lines[before:] if l.startswith("DIAL_CLOSED") and "why=Fenced" in l]
        t.check(late == 0 and early > 0 and len(fenced) == 1, f"RT-14g a dialled connection under a tag whose deadline passes: {early} bytes before, {late} after, closed as Fenced ({fenced})")
        rec.stop()
        # 9: drain with nothing left behind is the engine's; here: the program is up and silent
        t.check(r.p.poll() is None, "the program is up")
    finally:
        r.stop(); echo.stop()
    # 6: many concurrent dials across two workers, no leaked slots
    echo = Echo()
    r = Run(workers=2)
    try:
        results = []
        def one():
            try:
                _, st, b = r.get(f"/via/{echo.port}", timeout=30); results.append((st, b))
            except OSError as e: results.append((0, repr(e)))
        ths = [threading.Thread(target=one) for _ in range(200)]
        [x.start() for x in ths]; [x.join() for x in ths]
        good = sum(1 for st, b in results if st == 200 and b == b"hello")
        t.check(good == 200, f"RT-14i 200 concurrent dials across 2 workers all complete ({good} of 200)")
        time.sleep(0.5)
        opens = []
        for _ in range(30):
            _, st, b = r.get("/open"); opens.append(int(b))
        t.check(max(opens) <= 1, f"RT-14i no leaked slots afterwards: open connections seen by 30 fresh requests, at most {max(opens)} (want <= 1)")
    finally:
        r.stop(); echo.stop()

t.run(body)
t.finish()
