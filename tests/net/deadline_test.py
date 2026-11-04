#!/usr/bin/env python3
# Proves: RT-6a RT-6b RT-6d RT-6e   (tags, deadlines and fences; RT-6c, the clock, is tests/unit/clock_test.goose)
#
#     tests/net/deadline_test.py
#
# forward_server --control with tagged routes: listener A is tag 7 generation 1, B is tag 7 generation 2, C is tag 8. The control
# thread posts Message.Deadline and Message.CloseTagged. Deadlines are absolute CLOCK_BOOTTIME milliseconds, so the test reads the
# same clock (netlib.boottime_ms). The backend stamps every chunk it receives with that clock, which is how "zero bytes forwarded
# after the deadline" is checked from outside.
import os, signal, socket, struct, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("deadline_test", "RT-6a RT-6b RT-6d RT-6e")
host_lock()

class Stamping:
    """A backend that echoes and records (arrival boottime ms, bytes) for everything it receives."""
    def __init__(self, port):
        self.port = port
        self.arrivals = []
        self.lock = threading.Lock()
        self.backend = ThreadedBackend(port, self.handle)
    def handle(self, c):
        c.settimeout(30)
        while True:
            try:
                d = c.recv(65536)
            except (socket.timeout, ConnectionResetError):
                return
            if not d:
                return
            with self.lock:
                self.arrivals.append((boottime_ms(), len(d)))
            try: c.sendall(d)
            except OSError: return
    def bytes_after(self, ms):
        with self.lock:
            return sum(n for at, n in self.arrivals if at > ms)
    def total(self):
        with self.lock:
            return sum(n for at, n in self.arrivals)
    def stop(self):
        self.backend.stop()

def rig(fenced=(), workers=1):
    back = Stamping(free_port())
    ports = {k: free_port() for k in "ABC"}
    extra = ["--control",
             "--tagged-route", f"127.0.0.1:{ports['A']}=127.0.0.1:{back.port}@7:1",
             "--tagged-route", f"127.0.0.1:{ports['B']}=127.0.0.1:{back.port}@7:2",
             "--tagged-route", f"127.0.0.1:{ports['C']}=127.0.0.1:{back.port}@8:1"]
    for f in fenced:
        extra += ["--fenced", str(f)]
    server = Server([], [], workers=workers, stat_ms=200, extra=extra)
    return back, server, ports

def ended(c, within):
    """True if the connection ends (EOF or reset) within `within` seconds; returns (bool, seconds)."""
    t0 = time.time()
    c.settimeout(within)
    try:
        d = c.recv(100)
        return d == b"", time.time() - t0
    except ConnectionResetError:
        return True, time.time() - t0
    except socket.timeout:
        return False, time.time() - t0

def works(c):
    try:
        c.sendall(b"ping")
        c.settimeout(2)
        return recv_exact(c, 4) == b"ping"
    except (OSError, EOFError):
        return False

# ----------------------------------------------------------------------------------------------- RT-6b

def close_tagged():
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        conns = {k: [connect(ports[k]) for _ in range(5)] for k in "ABC"}
        t.check(all(works(c) for cs in conns.values() for c in cs), "RT-6b 15 connections (tag 7 gen 1, tag 7 gen 2, tag 8) all work")
        t0 = time.time()
        server.command("close-tagged 7 1")
        res = [ended(c, 1.0) for c in conns["A"]]
        t.check(all(r[0] for r in res) and max(r[1] for r in res) <= 0.2, f"RT-6b close-tagged 7 1 closes the five tag-7 generation-1 connections within 200 ms ({max(r[1] for r in res):.2f}s)")
        t.check(all(works(c) for c in conns["B"]) and all(works(c) for c in conns["C"]), "RT-6b generation 2 of tag 7 and tag 8 are untouched")
        t.check(server.wait_closed("Fenced", lambda v: v == 5, timeout=2) == 5, f"RT-6b the five were closed as Fenced ({server.closed('Fenced')})")
        # a flood on a tag-7 connection stops at once: messages are handled before the events of the same pass
        flood = connect(ports["B"], timeout=5)
        stop = threading.Event()
        def blast():
            data = b"z" * 16384
            try:
                while not stop.is_set():
                    flood.sendall(data)
            except OSError:
                pass
        th = threading.Thread(target=blast, daemon=True); th.start()
        time.sleep(0.5)
        before = back.total()
        server.command("close-tagged 7 2")
        time.sleep(0.05)
        at_cut = back.total()
        time.sleep(0.3)
        after = back.total()
        stop.set(); th.join(2); flood.close()
        t.check(before > 0, "RT-6b the flood was reaching the backend before the cut")
        t.check(after == at_cut, f"RT-6b within 50 ms of close-tagged the backend stops receiving: {at_cut} bytes at 50 ms, {after} 300 ms later")
        t.check(all(ended(c, 1.0)[0] for c in conns["B"]), "RT-6b close-tagged 7 2 closed generation 2 as well")
        t.check(works(conns["C"][0]), "RT-6b and tag 8 still works")
    finally:
        server.stop(); back.stop()

# ----------------------------------------------------------------------------------------------- RT-6a

class Sender(threading.Thread):
    """Sends a stamped 16-byte chunk every 20 ms on a connection, until it fails."""
    def __init__(self, c):
        super().__init__(daemon=True)
        self.c = c; self.sent = []; self.stop_flag = False
    def run(self):
        while not self.stop_flag:
            try:
                self.c.sendall(struct.pack(">QQ", boottime_ms(), 0))
                self.sent.append(boottime_ms())
            except OSError:
                return
            time.sleep(0.02)

def deadline_reached(frozen):
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        until = boottime_ms() + (6000 if frozen else 3000)
        server.command(f"deadline 7 {until}")
        time.sleep(0.2)
        c = connect(ports["A"], timeout=10)
        other = connect(ports["C"], timeout=10)
        t.check(works(c) and works(other), "RT-6a before the deadline the tagged connection works")
        sender = Sender(c)
        sender.start()
        if frozen:
            # Freeze the whole process from 1 s before the deadline to 2.5 s after it, while the client keeps sending, so the
            # first thing the engine sees on waking is readable data on a connection whose deadline has passed.
            while boottime_ms() < until - 1000:
                time.sleep(0.02)
            server.proc.send_signal(signal.SIGSTOP)
            frozen_at = boottime_ms()
            while boottime_ms() < until + 2500:
                time.sleep(0.02)
            at_wake = back.total()
            server.proc.send_signal(signal.SIGCONT)
            woke = boottime_ms()
            gone, secs = ended(c, 1.5)
            t.check(woke - frozen_at >= 3500 and woke > until + 2000, f"RT-6a the process was stopped {woke - frozen_at} ms, {woke - until} ms past the deadline")
            t.check(back.total() == at_wake, f"RT-6a after SIGCONT the backend received nothing more ({at_wake} bytes before, {back.total()} after)")
            t.check(gone, f"RT-6a the connection was closed when the process woke ({secs:.2f}s)")
        else:
            while boottime_ms() < until + 400:
                time.sleep(0.02)
            gone, secs = ended(c, 0.5)
            t.check(gone, "RT-6a at the deadline the tagged connection is closed")
        sender.stop_flag = True
        t.check(back.bytes_after(until + 50) == 0, f"RT-6a zero bytes reached the backend after the deadline (+50 ms): {back.bytes_after(until + 50)} bytes")
        if not frozen:
            t.check(back.total() > 16 * 20, "RT-6a and traffic did flow before the deadline")
        t.check(server.wait_closed("Fenced", lambda v: v >= 1, timeout=3) >= 1, "RT-6a the tag's connection was closed as Fenced")
        t.check(works(other), "RT-6a tag 8 (no deadline set) is not affected")
    finally:
        try: server.proc.send_signal(signal.SIGCONT)
        except Exception: pass
        server.stop(); back.stop()

# ----------------------------------------------------------------------------------------------- RT-6d

def latest_wins():
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        T = boottime_ms() + 2500
        server.command(f"deadline 7 {T}")
        server.command(f"deadline 7 {T - 1500}")        # earlier: ignored
        server.command(f"deadline 7 {T}")               # a duplicate: harmless
        time.sleep(0.2)
        c = connect(ports["A"], timeout=10)
        t.check(works(c), "RT-6d a connection works after three deadline messages (T, an earlier one, a duplicate of T)")
        while boottime_ms() < T - 700:
            time.sleep(0.02)
        t.check(works(c), "RT-6d the earlier deadline did not shorten it: still open 700 ms before T")
        server.command(f"deadline 7 {T + 2000}")       # a renewal
        while boottime_ms() < T + 600:
            time.sleep(0.02)
        t.check(works(c), "RT-6d a later deadline renews it: still open 600 ms past T")
        gone, secs = ended(c, 3.0)
        closed_at = boottime_ms()
        t.check(gone and T + 1800 <= closed_at <= T + 2400, f"RT-6d it closes at the renewed deadline T + 2000 ({closed_at - T} ms past T)")
    finally:
        server.stop(); back.stop()

# ----------------------------------------------------------------------------------------------- RT-6e

def fenced_start():
    back, server, ports = rig(fenced=(7,))
    try:
        server.start().wait_ready()
        c = connect(ports["A"], timeout=5)
        gone, secs = ended(c, 1.0)
        t.check(gone and secs <= 0.2, f"RT-6e a tag that starts fenced: its connection is closed at once ({secs:.2f}s)")
        c.close()
        other = connect(ports["C"], timeout=5)
        t.check(works(other), "RT-6e other tags are not fenced")
        server.command(f"deadline 7 {boottime_ms() + 1500}")
        time.sleep(0.2)
        c = connect(ports["A"], timeout=5)
        t.check(works(c), "RT-6e after a deadline in the future arrives the tag is served")
        gone, secs = ended(c, 3.0)
        t.check(gone, "RT-6e and closed again when the deadline passes")
        c.close()
        late = connect(ports["A"], timeout=5)
        gone, secs = ended(late, 1.0)
        t.check(gone and secs <= 0.2, f"RT-6e a new connection after the deadline is closed at once ({secs:.2f}s)")
        t.check(server.alive() and not server.stderr, f"RT-6e the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); back.stop()

t.run(close_tagged)
t.run(lambda: deadline_reached(False))
t.run(lambda: deadline_reached(True))
t.run(latest_wins)
t.run(fenced_start)
t.finish()
