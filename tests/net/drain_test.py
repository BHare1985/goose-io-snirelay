#!/usr/bin/env python3
# Proves: RT-8a RT-8b RT-8c   (drain: the listener closes at once, existing connections finish, the process exits when the last one
#                              closes or at the deadline; SIGTERM and SIGINT start the same drain)
#
#     tests/net/drain_test.py
#
# `drain MS` comes in on forward_server's control thread (--control) as a Message.Drain posted to every worker; SIGTERM and SIGINT
# come to a forward_server without --control, whose main calls wait_for_signal_then_drain(--drain-ms). "Exits" means the process
# ends with status 0.
import os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("drain_test", "RT-8a RT-8b RT-8c")
host_lock()

def refused(port, within=0.2):
    """True if a connect to the port is refused (nothing is listening) within `within` seconds."""
    t0 = time.time()
    try:
        connect(port, timeout=1).close()
        return False
    except ConnectionRefusedError:
        return time.time() - t0 <= within + 0.5
    except OSError:
        return False

def ping(c):
    c.sendall(b"ping")
    return recv_exact(c, 4) == b"ping"

def listening(port):
    """True if some socket listens on the port. Asked of the kernel with a port filter (`ss`, sock_diag), not by reading /proc/net/tcp: that file
    lists every socket of the host (28,000 lines while another team's load test runs, 60 ms to read), which made this test measure its own reading."""
    out = subprocess.run(["ss", "-H", "-ltn", f"sport = :{port}"], capture_output=True, text=True).stdout
    return bool(out.strip())

def wait_refused(port, seconds):
    """Seconds until nothing listens on the port any more, or None. (Named for what it used to do: it used to probe with connects, but a
    SYN that reaches an SO_REUSEPORT listener in the instant it closes is dropped by the kernel and retried after 1 s, which a connect
    probe cannot tell from "still listening": the listener table says what the engine did. The client-visible stalls are measured in
    drain_stall_test.)"""
    t0 = time.time()
    while time.time() - t0 < seconds:
        if not listening(port):
            return time.time() - t0
        time.sleep(0.005)
    return None

# ----------------------------------------------------------------------------------------------- RT-8a, RT-8b

def drain_by_command():
    bport, port = free_port(), free_port()
    echo = EchoBackend(bport)
    a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--control"])
    b = None
    try:
        a.start().wait_ready()
        held = connect(port, timeout=10)
        t.check(ping(held), "RT-8a a connection is open and working before the drain")
        a.command("drain 30000")
        took = wait_refused(port, 1.0)
        t.check(took is not None and took <= 0.3, f"RT-8a after `drain`, the listener is closed at once: no LISTEN entry for the port ({'%.2fs' % took if took is not None else 'never'})")
        # A new process on the same port gets every new connection.
        b = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200)
        b.start().wait_ready()
        # `accepted` comes from the stat lines, up to one period old: the probes above may have been accepted by the
        # second worker a moment before its listener closed. Wait until both workers have reported after the listeners
        # were seen closed (two lines each), so `before` includes every connection accepted before the drain took effect.
        seen_lines = a.stat_lines
        t0_wait = time.time()
        while a.stat_lines < seen_lines + 4 and time.time() - t0_wait < 3:
            time.sleep(0.02)
        before = a.total("accepted")
        ok = 0
        for i in range(50):
            c = connect(port, timeout=5)
            ok += 1 if ping(c) else 0
            c.close()
        got = b.wait_stat("accepted", lambda v: v >= 50, timeout=4)
        t.check(ok == 50 and got == 50, f"RT-8a a new process on the same port gets all 50 new connections (served {ok}, it counted {got})")
        t.check(a.total("accepted") == before, f"RT-8a the draining process accepted none of them ({a.total('accepted')} vs {before} before)")
        t.check(ping(held), "RT-8a the connection that was open before the drain keeps working during it")
        t.check(a.alive(), "RT-8b the draining process is still running while a connection is open")
        # The last connection closes: the drain is over and the process exits.
        held.close()
        secs, status = a.wait_exit(2.0)
        t.note(f"RT-8b measured: exit {secs:.2f}s after the last connection closed, status {status}")
        t.check(status == 0 and secs <= 0.5 + 0.3, f"RT-8b the process exits with status 0 shortly after its last connection closes ({secs:.2f}s, status {status})")
    finally:
        a.stop(); echo.stop()
        if b: b.stop()

def drain_deadline_by_command():
    bport, port = free_port(), free_port()
    echo = EchoBackend(bport)
    a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--control"])
    try:
        a.start().wait_ready()
        held = connect(port, timeout=10)
        ping(held)
        t0 = time.time()
        a.command("drain 1000")
        held.settimeout(4)
        try:
            ended = held.recv(10) == b""
        except ConnectionResetError:
            ended = True
        except socket.timeout:
            ended = False
        closed_at = time.time() - t0
        secs, status = a.wait_exit(3.0)
        total = time.time() - t0
        t.note(f"RT-8b measured: held connection closed at {closed_at:.2f}s, process exited at {total:.2f}s (deadline 1.0 s), status {status}")
        t.check(ended and 0.9 <= closed_at <= 1.3, f"RT-8b a connection still open at the deadline is closed then ({closed_at:.2f}s for a 1.0 s deadline)")
        t.check(status == 0 and total <= 1.3, f"RT-8b the process exits with status 0 at the deadline + 300 ms at most ({total:.2f}s, status {status})")
    finally:
        a.stop(); echo.stop()

# ----------------------------------------------------------------------------------------------- RT-8c

def drain_by_signal(sig, name):
    bport, port = free_port(), free_port()
    echo = EchoBackend(bport)
    # held open past the deadline
    a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--drain-ms", "2000"])
    try:
        a.start().wait_ready()
        held = connect(port, timeout=10)
        ping(held)
        t0 = time.time()
        a.proc.send_signal(sig)
        took = wait_refused(port, 1.0)
        t.check(took is not None and took <= 0.3, f"RT-8c {name} closes the listener at once: no LISTEN entry for the port ({'%.2fs' % took if took is not None else 'never'})")
        t.check(ping(held), f"RT-8c {name}: an open connection keeps working during the drain")
        held.settimeout(4)
        try:
            ended = held.recv(10) == b""
        except ConnectionResetError:
            ended = True
        except socket.timeout:
            ended = False
        closed_at = time.time() - t0
        secs, status = a.wait_exit(3.0)
        total = time.time() - t0
        t.check(ended and 1.9 <= closed_at <= 2.3, f"RT-8c {name}: a connection still open at the 2 s deadline is closed then ({closed_at:.2f}s)")
        t.check(status == 0 and total <= 2.3, f"RT-8c {name}: exit status 0 at the deadline ({total:.2f}s, status {status})")
    finally:
        a.stop()
    # no connections: it ends at once; one that closes early: it ends then
    a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--drain-ms", "2000"])
    try:
        a.start().wait_ready()
        a.proc.send_signal(sig)
        secs, status = a.wait_exit(2.5)
        t.check(status == 0 and secs <= 0.5, f"RT-8c {name} with nothing open: the process exits with status 0 at once ({secs:.2f}s, status {status})")
    finally:
        a.stop()
    a = Server([f"127.0.0.1:{port}"], [f"127.0.0.1:{bport}"], workers=2, stat_ms=200, extra=["--drain-ms", "5000"])
    try:
        a.start().wait_ready()
        c = connect(port, timeout=10)
        ping(c)
        a.proc.send_signal(sig)
        time.sleep(0.5)
        c.close()
        t0 = time.time()
        secs, status = a.wait_exit(2.0)
        t.check(status == 0 and secs <= 0.8, f"RT-8c {name}: when the last connection closes before the deadline the process exits then ({secs:.2f}s after it, status {status})")
    finally:
        a.stop(); echo.stop()

t.run(drain_by_command)
t.run(drain_deadline_by_command)
t.run(lambda: drain_by_signal(signal.SIGTERM, "SIGTERM"))
t.run(lambda: drain_by_signal(signal.SIGINT, "SIGINT"))
t.finish()
