#!/usr/bin/env python3
# Proves: RT-6f   (Message.ReplaceDeadline sets a tag's deadline exactly: shorter, longer or cleared; the frozen-process fence holds)
#
#     tests/net/replace_deadline_test.py                    one pass (about 25 s)
#     REPEAT=100 tests/run_tests.sh replace_deadline        the release gate: 100 runs, alone, then 100 under load
#
# Why: verify_backends.py t_lease renews a lease with 5000 ms and then sets 300 ms, freezes the proxy (SIGSTOP) past the 300 ms and
# requires that nothing is forwarded after SIGCONT. `lease off` ends the deadline. tcprouter's Deadline message (RT-6d) is
# latest-wins: an earlier until_ms is ignored, so after the 5000 the engine's fence would stay at 5000. ReplaceDeadline is the
# message that sets it exactly. One control thread writes the workers' FIFO pipes, so a replace cannot overtake an older message.
#
# The harness: forward_server --control gains
#     replace-deadline TAG BOOTTIME_MS        posts Message.ReplaceDeadline { tag, until_ms }   (BOOTTIME_MS 0 clears)
# and is otherwise as in deadline_test.py (listener A is tag 7 generation 1, B is tag 7 generation 2, C is tag 8). Without the
# command the server ignores the line, so today every scenario below fails: the red.
import os, signal, socket, struct, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("replace_deadline_test", "RT-6f")
host_lock()

class Stamping:
    """A backend that echoes, records (arrival boottime ms, bytes) of what it receives, and pushes 16 bytes every 20 ms unasked."""
    def __init__(self, port):
        self.port = port
        self.arrivals = []
        self.lock = threading.Lock()
        self.backend = ThreadedBackend(port, self.handle)
    def handle(self, c):
        c.settimeout(30)
        done = []
        def pusher():
            while not done:
                try: c.sendall(b"S" * 16)
                except OSError: return
                time.sleep(0.02)
        threading.Thread(target=pusher, daemon=True).start()
        try:
            while True:
                try: d = c.recv(65536)
                except (socket.timeout, ConnectionResetError): return
                if not d: return
                with self.lock: self.arrivals.append((boottime_ms(), len(d)))
                try: c.sendall(d)
                except OSError: return
        finally:
            done.append(1)
    def bytes_after(self, ms):
        with self.lock: return sum(n for at, n in self.arrivals if at > ms)
    def total(self):
        with self.lock: return sum(n for at, n in self.arrivals)
    def stop(self): self.backend.stop()

class Receiver(threading.Thread):
    """Records (arrival boottime ms, bytes) of everything the client receives, until the connection ends."""
    def __init__(self, c):
        super().__init__(daemon=True)
        self.c = c; self.arrivals = []; self.ended_at = None
    def run(self):
        self.c.settimeout(20)
        while True:
            try: d = self.c.recv(65536)
            except OSError: d = b""
            if not d:
                self.ended_at = boottime_ms(); return
            self.arrivals.append((boottime_ms(), len(d)))
    def after(self, ms): return sum(n for at, n in self.arrivals if at > ms)

class Sender(threading.Thread):
    """Sends 16 bytes every 20 ms on a connection until it fails."""
    def __init__(self, c):
        super().__init__(daemon=True)
        self.c = c; self.stop_flag = False
    def run(self):
        while not self.stop_flag:
            try: self.c.sendall(struct.pack(">QQ", boottime_ms(), 0))
            except OSError: return
            time.sleep(0.02)

def replace_deadline(server, tag, until):
    """Sends the command and waits for the program's ACK, which it prints once every worker has applied the message. Without the wait a
    SIGSTOP right after the command can land between the control thread reading the line and the pipe write, and the fence is then late
    by the length of the freeze (seen once in 100 runs; found when running the gate)."""
    before = sum(1 for l in server.lines if l == "ACK replace-deadline")
    server.command(f"replace-deadline {tag} {until}")
    for _ in range(300):
        if sum(1 for l in server.lines if l == "ACK replace-deadline") > before: return
        time.sleep(0.01)

def rig(fenced=()):
    back = Stamping(free_port())
    ports = {k: free_port() for k in "AC"}
    extra = ["--control",
             "--tagged-route", f"127.0.0.1:{ports['A']}=127.0.0.1:{back.port}@7:1",
             "--tagged-route", f"127.0.0.1:{ports['C']}=127.0.0.1:{back.port}@8:1"]
    for f in fenced: extra += ["--fenced", str(f)]
    return back, Server([], [], workers=2, stat_ms=200, extra=extra), ports

def works(c):
    try:
        c.sendall(b"ping"); c.settimeout(2)
        got = b""
        while b"ping" not in got:
            d = c.recv(64)
            if not d: return False
            got += d
        return True
    except OSError:
        return False

def open_for(c, secs):
    """True if the connection is still open after `secs` (data from the backend keeps arriving on it)."""
    c.settimeout(secs)
    try: return c.recv(100) != b""
    except socket.timeout: return True
    except OSError: return False

# ------------------------------------------------------------------------------------------------ shorter

def shorter(frozen):
    what = "RT-6f frozen" if frozen else "RT-6f shorter"
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        server.command(f"deadline 7 {boottime_ms() + 5000}")             # the lease renewed with 5000 ...
        time.sleep(0.2)
        c = connect(ports["A"], timeout=10)
        rx = Receiver(c); rx.start()
        sender = Sender(c); sender.start()
        ok = works(connect(ports["A"], timeout=10))
        for _ in range(100):                                              # the first echo can still be on its way
            if rx.arrivals: break
            time.sleep(0.02)
        t.check(ok and len(rx.arrivals) > 0, f"{what}: with 5000 ms of lease the tag serves")
        until = boottime_ms() + 300
        replace_deadline(server, 7, until)                    # ... then set to 300
        if frozen:
            server.proc.send_signal(signal.SIGSTOP)                       # t_lease stops the proxy right after the command
            frozen_at = boottime_ms()
            while boottime_ms() < until + 400: time.sleep(0.02)
            at_wake = back.total()
            server.proc.send_signal(signal.SIGCONT)
            woke = boottime_ms()
            t.check(woke - frozen_at >= 600 and woke > until + 300, f"{what}: the process was stopped {woke - frozen_at} ms, {woke - until} ms past the 300 ms deadline")
            t.check(back.total() == at_wake, f"{what}: after SIGCONT the backend received nothing more ({at_wake} bytes before, {back.total()} after)")
        else:
            while boottime_ms() < until + 500: time.sleep(0.02)
        time.sleep(0.3)
        t.check(rx.ended_at is not None and rx.ended_at <= until + 700, f"{what}: the connection was closed by the 300 ms deadline, not the 5000 ms one (ended {None if rx.ended_at is None else rx.ended_at - until} ms past it)")
        sender.stop_flag = True
        t.check(rx.after(until + 50) == 0, f"{what}: zero bytes reached the client after the deadline (+50 ms): {rx.after(until + 50)}")
        t.check(back.bytes_after(until + 50) == 0, f"{what}: zero bytes reached the backend after the deadline (+50 ms): {back.bytes_after(until + 50)}")
        late = connect(ports["A"], timeout=5)
        t.check(not open_for(late, 0.4), f"{what}: a new connection on the tag is refused")
        t.check(server.wait_closed("Fenced", lambda v: v >= 1, timeout=3) >= 1, f"{what}: closed as Fenced")
        other = connect(ports["C"], timeout=5)
        t.check(works(other), f"{what}: tag 8 is not affected")
        t.check(server.alive() and not server.stderr, f"{what}: the program is up and silent ({server.stderr[:2]})")
    finally:
        try: server.proc.send_signal(signal.SIGCONT)
        except Exception: pass
        server.stop(); back.stop()

# ------------------------------------------------------------------------------------------------ longer and cleared

def longer():
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        server.command(f"deadline 7 {boottime_ms() + 300}")
        time.sleep(0.1)
        c = connect(ports["A"], timeout=10)
        t.check(works(c), "RT-6f longer: serves under a 300 ms deadline")
        replace_deadline(server, 7, boottime_ms() + 3000)      # replace may also lengthen
        time.sleep(0.8)
        t.check(works(c), "RT-6f longer: still open 800 ms later, past the old deadline")
    finally:
        server.stop(); back.stop()

def cleared():
    back, server, ports = rig()
    try:
        server.start().wait_ready()
        server.command(f"deadline 7 {boottime_ms() + 700}")
        time.sleep(0.1)
        c = connect(ports["A"], timeout=10)
        t.check(works(c), "RT-6f clear: serves under a 700 ms deadline")
        replace_deadline(server, 7, 0)                            # lease off
        time.sleep(1.2)
        t.check(works(c), "RT-6f clear: with the deadline cleared the connection outlives it")
        t.check(works(connect(ports["A"], timeout=5)), "RT-6f clear: new connections are served, with no deadline at all")
        t.check(server.closed("Fenced") == 0, f"RT-6f clear: nothing was closed as Fenced ({server.closed('Fenced')})")
    finally:
        server.stop(); back.stop()

def cleared_lifts_a_start_fence():
    back, server, ports = rig(fenced=(7,))
    try:
        server.start().wait_ready()
        t.check(not open_for(connect(ports["A"], timeout=5), 0.4), "RT-6f clear: a tag that starts fenced refuses connections")
        replace_deadline(server, 7, 0)
        time.sleep(0.2)
        t.check(works(connect(ports["A"], timeout=5)), "RT-6f clear: replace 0 lifts the start fence too (`lease off` on a server that did not require a lease)")
    finally:
        server.stop(); back.stop()

t.run(lambda: shorter(False))
t.run(lambda: shorter(True))
t.run(longer)
t.run(cleared)
t.run(cleared_lifts_a_start_fence)
t.finish()
