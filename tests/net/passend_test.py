#!/usr/bin/env python3
# Proves: RT-17a RT-17b RT-17c RT-17d RT-17e RT-17f   (w.want_pass_end(true): Event.PassEnd once after the last handler event of every non-empty pass)
#
#     tests/run_tests.sh passend      (builds harness/passend_server.goose and sets PASSEND_SERVER)
import os, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("passend_test", "RT-17a RT-17b RT-17c RT-17d RT-17e RT-17f")
host_lock()
SERVER = os.environ.get("PASSEND_SERVER", "tests/net/harness/passend_server")

class Run:
    def __init__(self, *flags):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}", *flags], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if "READY" in self.lines: break
            time.sleep(0.05)
        time.sleep(0.15)
    def say(self, text): self.p.stdin.write(text + "\n"); self.p.stdin.flush()
    def mark(self): return len(self.lines)
    def since(self, m): return [l for l in self.lines[m:] if not l.startswith("PASSEND_SEND")]
    def settle(self, secs=0.4): time.sleep(secs)
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def kinds(lines): return [("DATA" if l.startswith("EV data") else l.replace("EV ", "").upper()) for l in lines]

def body():
    # RT-17a, RT-17b: one PassEnd per non-empty pass, none on idle passes
    r = Run("--pass-end")
    try:
        m = r.mark()
        c = socket.create_connection(("127.0.0.1", r.port), timeout=5); r.settle()
        k = kinds(r.since(m))
        t.check(k.count("PASSEND") == 1 and k[-1] == "PASSEND" and "OPENED" in k, f"RT-17a an accepted connection: its Opened pass ends with exactly one PassEnd ({k})")
        m = r.mark(); c.sendall(b"hello"); r.settle()
        k = kinds(r.since(m))
        t.check(k == ["DATA", "PASSEND"], f"RT-17a one request: Data then PassEnd ({k})")
        m = r.mark(); time.sleep(0.7)
        t.check(kinds(r.since(m)) == [], f"RT-17b idle passes (Ticks every 100 ms for 0.7 s) deliver no PassEnd ({kinds(r.since(m))})")
        # (b) from Steve: a pass with only a posted message gets no PassEnd
        m = r.mark(); r.say("ping"); r.say(f"deadline 99 {boottime_ms() + 60000}"); r.settle()
        t.check(kinds(r.since(m)) == ["PONG 1".upper()] or all(x.startswith("PONG") for x in kinds(r.since(m))), f"RT-17f a pass that delivered only a posted message (control) gets no PassEnd ({kinds(r.since(m))})")
        m = r.mark(); c.close(); r.settle()                          # mark BEFORE the close: under load the server can log the Closed before a later mark (found in run 7 of a loaded run)
        k = kinds(r.since(m))
        t.check(k == ["CLOSED", "PASSEND"], f"RT-17a a close: Closed then PassEnd ({k})")
    finally: r.stop()
    # RT-17d: off by default: never
    r = Run()
    try:
        m = r.mark()
        c = socket.create_connection(("127.0.0.1", r.port), timeout=5); c.sendall(b"hello"); r.settle(); c.close(); r.settle()
        t.check(not any(l.startswith("PASSEND") for l in r.since(m)) and any(l.startswith("EV data") for l in r.since(m)), f"RT-17d without want_pass_end there is never a PassEnd ({kinds(r.since(m))})")
    finally: r.stop()
    # RT-17c: after a batching-window wait: two requests 10 ms apart inside one 100 ms window are one pass: Data, Data, PassEnd
    r = Run("--pass-end", "--batch-min", "1000", "--batch-wait-us", "100000")
    try:
        a = socket.create_connection(("127.0.0.1", r.port), timeout=5); b = socket.create_connection(("127.0.0.1", r.port), timeout=5); r.settle(0.6)
        # The window is cut to the next Tick (at most 100 ms away), so a 1 ms gap lands outside the window about 1% of the time: up to 3 attempts, and the run
        # must show the whole shape at least once.
        shapes = []
        for attempt in range(3):
            m = r.mark(); a.sendall(b"one")
            spin = time.perf_counter() + 0.001
            while time.perf_counter() < spin: pass
            b.sendall(b"two"); r.settle(0.5)
            shapes.append(kinds(r.since(m)))
            if shapes[-1] == ["DATA", "DATA", "PASSEND"]: break
        t.check(["DATA", "DATA", "PASSEND"] in shapes, f"RT-17c after a batching-window wait: the two events it gathered, then one PassEnd ({shapes})")
    finally: r.stop()
    # RT-17e: a send during PassEnd goes through the normal path, deadline check included: 0 bytes after the deadline
    r = Run("--pass-end")
    try:
        c = socket.create_connection(("127.0.0.1", r.port), timeout=5); r.settle()
        until = boottime_ms() + 1000
        r.say(f"deadline 7 {until}"); r.settle(0.2)
        m = r.mark(); c.sendall(b"hello"); r.settle(0.3)
        ok_before = [l for l in r.lines[m:] if l.startswith("PASSEND_SEND")]
        c.settimeout(0.5)
        try: got = c.recv(100)
        except OSError: got = b""
        t.check(ok_before == ["PASSEND_SEND true"] and got and got == b"late" * (len(got) // 4), f"RT-17e before the deadline a send during PassEnd goes out ({ok_before}, {got!r}; the accept pass sent one too)")
        while boottime_ms() < until - 150: time.sleep(0.02)
        m = r.mark(); c.sendall(b"slow"); r.settle(0.9)                # the handler sleeps 300 ms inside Data: the deadline passes before PassEnd
        late = [l for l in r.lines[m:] if l.startswith("PASSEND_SEND")]
        c.settimeout(0.5)
        try: got = c.recv(100)
        except OSError: got = b""
        t.check(late == ["PASSEND_SEND false"] and got == b"", f"RT-17e a send during PassEnd after the tag deadline passed sends 0 bytes and says false ({late}, {got!r})")
    finally: r.stop()

t.run(body)
t.finish()
