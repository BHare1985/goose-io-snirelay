#!/usr/bin/env python3
# Proves: RT-6a-H   (a Handle-tagged connection sends nothing after its deadline: not an echo, not a push, not when the
#                    worker is held up inside the user's code, and not when the whole process is stopped mid-pass)
#
#     tests/net/handler_deadline_test.py
#
# The system under test is harness/handler_server.goose with --control. Tags 7 and 8 echo every byte and also push 16 bytes on
# every Tick; the tag is the fencing tag (Action.Handle { tag }), so a deadline for tag 7 fences the tag-7 route and tag 8 is the
# control group (never given a deadline). Deadlines are absolute CLOCK_BOOTTIME milliseconds, read from the same clock as the
# engine (netlib.boottime_ms); the client stamps every byte it receives with that clock, which is how "nothing after the
# deadline" is checked from outside, as in deadline_test.py for forwarding.
#
#   stall   The worker is held up INSIDE the user's Data handler (--stall-ms) across the deadline, then calls send(): deterministic.
#   frozen  SIGSTOP from 1 s before the deadline to 2.5 s after it while the client keeps sending (as deadline_test.py, RT-6a).
#   plain   Nothing special: at the deadline the connection is closed and nothing arrives after it.
import os, signal, struct, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("handler_deadline_test", "RT-6a-H")
host_lock()

class Receiver(threading.Thread):
    """Records (arrival boottime ms, bytes) of everything the client receives, until the connection ends."""
    def __init__(self, c):
        super().__init__(daemon=True)
        self.c = c; self.arrivals = []; self.ended = False
    def run(self):
        self.c.settimeout(20)
        while True:
            try:
                d = self.c.recv(65536)
            except OSError:
                self.ended = True
                return
            if not d:
                self.ended = True
                return
            self.arrivals.append((boottime_ms(), len(d)))
    def after(self, ms):
        return sum(n for at, n in self.arrivals if at > ms)

class Sender(threading.Thread):
    """Sends a 16-byte chunk every 20 ms on a connection, until it fails."""
    def __init__(self, c):
        super().__init__(daemon=True)
        self.c = c; self.stop_flag = False
    def run(self):
        while not self.stop_flag:
            try:
                self.c.sendall(struct.pack(">QQ", boottime_ms(), 0))
            except OSError:
                return
            time.sleep(0.02)

def rig(stall_ms=0):
    ports = {k: free_port() for k in "AB"}
    handles = [f"127.0.0.1:{ports['A']}=7", f"127.0.0.1:{ports['B']}=8"]
    extra = ["--control", "--log-events"] + (["--stall-ms", str(stall_ms)] if stall_ms else [])
    return Server([], [], exe=HANDLER_SERVER, handles=handles, extra=extra, stat_ms=200), ports

def closed_as(server, why):
    with server._lock:
        return sum(1 for l in server.lines if l.startswith("E closed") and f"why=CloseReason.{why}" in l)

def wait_ended(rx, seconds):
    t0 = time.time()
    while not rx.ended and time.time() - t0 < seconds:
        time.sleep(0.02)
    return rx.ended

# ----------------------------------------------------------------------------------------------- stall

def stall():
    server, ports = rig(stall_ms=1500)
    try:
        server.start().wait_ready()
        until = boottime_ms() + 1500
        server.command(f"deadline 7 {until}")
        time.sleep(0.2)
        a = connect(ports["A"], timeout=10)
        b = connect(ports["B"], timeout=10)
        ra, rb = Receiver(a), Receiver(b)
        ra.start(); rb.start()
        while boottime_ms() < until - 700:
            time.sleep(0.01)
        a.sendall(b"A" * 16)                          # arrives before the deadline; the handler then waits 1.5 s, past it
        b.sendall(b"B" * 16)
        while boottime_ms() < until + 2500:
            time.sleep(0.02)
        t.check(ra.after(until + 50) == 0, f"RT-6a-H stall: the Handle-tagged connection received nothing after its deadline ({ra.after(until + 50)} bytes)")
        t.check(wait_ended(ra, 1.0), "RT-6a-H stall: ... and it was closed")
        t.check(closed_as(server, "Fenced") >= 1, f"RT-6a-H stall: ... as Fenced ({closed_as(server, 'Fenced')})")
        t.check(not rb.ended and rb.after(until + 50) > 0, "RT-6a-H stall: the tag without a deadline is not affected: still open, still receiving")
        t.check(server.alive(), "RT-6a-H stall: the worker is up")
    finally:
        server.stop()

# ----------------------------------------------------------------------------------------------- frozen, plain

def deadline_reached(frozen):
    server, ports = rig()
    try:
        server.start().wait_ready()
        until = boottime_ms() + (6000 if frozen else 3000)
        server.command(f"deadline 7 {until}")
        time.sleep(0.2)
        c = connect(ports["A"], timeout=10)
        other = connect(ports["B"], timeout=10)
        rx = Receiver(c)
        rx.start()
        time.sleep(0.3)
        t.check(len(rx.arrivals) > 0, "RT-6a-H before the deadline the tagged connection receives data")
        sender = Sender(c)
        sender.start()
        if frozen:
            while boottime_ms() < until - 1000:
                time.sleep(0.02)
            server.proc.send_signal(signal.SIGSTOP)
            frozen_at = boottime_ms()
            while boottime_ms() < until + 2500:
                time.sleep(0.02)
            server.proc.send_signal(signal.SIGCONT)
            woke = boottime_ms()
            t.check(woke - frozen_at >= 3400 and woke > until + 2000, f"RT-6a-H the process was stopped {woke - frozen_at} ms, {woke - until} ms past the deadline")
        else:
            while boottime_ms() < until + 400:
                time.sleep(0.02)
        ended = wait_ended(rx, 1.5)
        sender.stop_flag = True
        time.sleep(0.2)
        t.check(ended, "RT-6a-H the connection was closed at the deadline" + (" (when the process woke)" if frozen else ""))
        t.check(rx.after(until + 50) == 0, f"RT-6a-H zero bytes reached the client after the deadline ({rx.after(until + 50)} bytes{', process stopped across it' if frozen else ''})")
        t.check(closed_as(server, "Fenced") >= 1, f"RT-6a-H it was closed as Fenced ({closed_as(server, 'Fenced')})")
        other.settimeout(2)
        other.sendall(b"ping")
        t.check(recv_exact(other, 4) is not None, "RT-6a-H the tag without a deadline still echoes")
    finally:
        try: server.proc.send_signal(signal.SIGCONT)
        except Exception: pass
        server.stop()

t.run(stall)
t.run(lambda: deadline_reached(False))
t.run(lambda: deadline_reached(True))
t.finish()
