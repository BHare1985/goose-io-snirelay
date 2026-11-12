#!/usr/bin/env python3
# Proves: RT-16a RT-16b RT-16c RT-16d RT-16e RT-16f   (the batching window: Limits.batch_min_events / batch_max_wait_us)
#
#     tests/run_tests.sh batch      (builds harness/batch_server.goose and sets BATCH_SERVER)
#
# OFF by default (both 0): the worker never waits (RT-16a). ON: a pass that finds fewer events than batch_min_events waits up to batch_max_wait_us for more, then
# processes (RT-16b). Rules: it never waits past a deadline (RT-16c); a posted message ends the wait at once, so a Stats gather is as fast as without the window
# (RT-16d); fencing is unaffected (RT-16e). RT-16f prints the CPU and latency rows with the window on and off (CPU per request, p50/p95 latency) and gates only
# that the p95 does not grow by more than the window's order of magnitude.
import os, socket, statistics, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("batch_test", "RT-16a RT-16b RT-16c RT-16d RT-16e RT-16f")
host_lock()
SERVER = os.environ.get("BATCH_SERVER", "tests/net/harness/batch_server")

class Backend:
    """Echo; records (boottime ms, bytes) of what it receives."""
    def __init__(self):
        self.port = free_port()
        self.sock = socket.socket(); self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port)); self.sock.listen(128)
        self.received = []
        threading.Thread(target=self.loop, daemon=True).start()
    def loop(self):
        while True:
            try: c, _ = self.sock.accept()
            except OSError: return
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()
    def serve(self, c):
        try:
            while (d := c.recv(4096)):
                self.received.append((boottime_ms(), len(d))); c.sendall(d)
        except OSError: pass
        c.close()
    def stop(self): self.sock.close()

class Run:
    def __init__(self, backend, bmin=0, bwait=0, tag=0, workers=1):
        self.port = free_port()
        args = [SERVER, "--listen", f"127.0.0.1:{self.port}", "--to", f"127.0.0.1:{backend.port}", "--batch-min", str(bmin), "--batch-wait-us", str(bwait), "--workers", str(workers)]
        if tag: args += ["--tagged", str(tag)]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if self.lines.count("READY") >= workers: break
            time.sleep(0.05)
    def say(self, text): self.p.stdin.write(text + "\n"); self.p.stdin.flush()
    def ask(self, cmd, prefix, secs=5):
        n = sum(1 for l in self.lines if l.startswith(prefix))
        self.say(cmd)
        end = time.time() + secs
        while time.time() < end:
            hits = [l for l in self.lines if l.startswith(prefix)]
            if len(hits) > n: return hits[-1]
            time.sleep(0.0005)
        return None
    def stats(self):
        line = self.ask("stats", "BATCH")
        return {k: int(v) for k, v in (x.split("=") for x in line.split()[1:])} if line else {}
    def cpu_ms(self):
        f = open(f"/proc/{self.p.pid}/stat").read().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12])) * 10
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def drive(port, conns=8, interval=0.004, seconds=2.5):
    """conns clients, each a 64-byte ping-pong every `interval` s; returns the latencies in ms."""
    lat = []; lock = threading.Lock(); stop_at = time.time() + seconds
    def one():
        c = socket.create_connection(("127.0.0.1", port), timeout=10); c.settimeout(10)
        mine = []
        while time.time() < stop_at:
            t0 = time.perf_counter(); c.sendall(b"x" * 64)
            got = 0
            while got < 64: got += len(c.recv(64 - got))
            mine.append((time.perf_counter() - t0) * 1000)
            time.sleep(interval)
        c.close()
        with lock: lat.extend(mine)
    ths = [threading.Thread(target=one) for _ in range(conns)]
    [x.start() for x in ths]; [x.join() for x in ths]
    return lat

def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(len(v) * p))] if v else float("nan")

def body():
    be = Backend()
    try:
        # RT-16a: off by default (and with only one of the two set): never waits
        for bmin, bwait, what in ((0, 0, "defaults"), (8, 0, "batch_min_events only"), (0, 2000, "batch_max_wait_us only")):
            r = Run(be, bmin, bwait)
            try:
                drive(r.port, seconds=1.0)
                s = r.stats()
                t.check(s.get("waits") == 0 and s.get("wait_us") == 0, f"RT-16a {what}: the worker never waits ({s})")
            finally: r.stop()
        # RT-16b and RT-16f: on versus off, the same load
        rows = {}
        for name, bmin, bwait in (("off", 0, 0), ("on", 8, 2000)):
            r = Run(be, bmin, bwait)
            try:
                time.sleep(0.3)
                c0 = r.cpu_ms()
                lat = drive(r.port)
                used = r.cpu_ms() - c0
                s = r.stats()
                rows[name] = (used, len(lat), pct(lat, 0.5), pct(lat, 0.95), s)
            finally: r.stop()
        for name, (used, n, p50, p95, s) in rows.items():
            t.note(f"RT-16f row {name}: {n} requests, {used} ms CPU ({used * 1000.0 / max(n, 1):.0f} us per request), latency p50 {p50:.2f} ms p95 {p95:.2f} ms, waits={s.get('waits')}")
        t.check(rows["on"][4].get("waits", 0) > 0 and rows["on"][4].get("wait_us", 0) > 0, f"RT-16b with min=8 and max_wait=2000 us the worker waits ({rows['on'][4]})")
        t.check(rows["on"][3] <= rows["off"][3] + 20, f"RT-16f the window does not add more than 20 ms to the p95 latency ({rows['off'][3]:.2f} -> {rows['on'][3]:.2f} ms)")
        # RT-16c and RT-16e: the window never passes a deadline; zero bytes after it
        be2 = Backend()
        r = Run(be2, bmin=1000, bwait=200000, tag=7)
        try:
            c = socket.create_connection(("127.0.0.1", r.port), timeout=10); c.settimeout(5)
            stopper = []
            def sender():
                while not stopper:
                    try: c.sendall(b"y" * 16)
                    except OSError: return
                    time.sleep(0.03)                                  # sparse: every pass finds 1 event, so every pass opens a window
            threading.Thread(target=sender, daemon=True).start()
            time.sleep(0.2)
            until = boottime_ms() + 403
            r.say(f"deadline 7 {until}")
            closed_at = None
            while True:
                try: d = c.recv(4096)
                except OSError: d = b""
                if not d: closed_at = boottime_ms(); break
            stopper.append(1)
            late = sum(n for at, n in be2.received if at > until + 20)
            t.check(closed_at is not None and closed_at - until <= 60, f"RT-16c a 200 ms window does not delay the deadline: the connection closed {None if closed_at is None else closed_at - until} ms after it (want <= 60)")
            t.check(late == 0, f"RT-16e zero bytes reach the backend after the deadline while the window is on ({late})")
        finally:
            r.stop(); be2.stop()
        # RT-16d: a posted message ends the wait at once: a Stats gather is as fast with a 200 ms window as without
        med = {}
        for name, bmin, bwait in (("off", 0, 0), ("on", 1000, 200000)):
            be3 = Backend(); r = Run(be3, bmin, bwait)
            try:
                stop = []
                def trickle():
                    c = socket.create_connection(("127.0.0.1", r.port), timeout=10)
                    while not stop:
                        try: c.sendall(b"z" * 16)
                        except OSError: return
                        time.sleep(0.003)
                threading.Thread(target=trickle, daemon=True).start()
                time.sleep(0.3)
                lat = []
                for _ in range(30):
                    t0 = time.perf_counter(); r.ask("ping", "PONG"); lat.append((time.perf_counter() - t0) * 1000); time.sleep(0.01)
                stop.append(1)
                med[name] = (statistics.median(lat), pct(lat, 0.95))
            finally:
                r.stop(); be3.stop()
        t.check(med["on"][0] <= med["off"][0] + 10 and med["on"][1] <= med["off"][1] + 25,
                f"RT-16d a Stats gather with a 200 ms window on: median {med['on'][0]:.1f} ms, p95 {med['on'][1]:.1f} ms; off: {med['off'][0]:.1f} / {med['off'][1]:.1f} (a message ends the wait at once)")
    finally:
        be.stop()

t.run(body)
t.finish()
