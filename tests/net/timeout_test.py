#!/usr/bin/env python3
# Proves: RT-7a RT-7b RT-7c RT-7d RT-4c   (connect, idle and half-close timeouts, each within limit + 300 ms; and the timed-out
#                                          half of RT-4c: a connect that never completes is retried on the next target)
#
#     tests/net/timeout_test.py
#
# A connect that never completes needs an address that swallows SYNs: netlib.BlackholeBackend (a listen(0) socket whose
# accept queue is full: deterministic, no firewall, no root). Limits are set short on the command line so the whole file
# runs in about 40 seconds. "Within limit + 300 ms" is RT-7d; the early edge (not before limit - 50 ms) guards against a
# timer that fires too soon.
import os, socket, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("timeout_test", "RT-7a RT-7b RT-7c RT-7d RT-4c")
host_lock()

def timed_close(c, patience=5.0):
    """Waits for the connection to end; returns (seconds, how) with how in 'eof', 'reset', 'open'."""
    t0 = time.time()
    c.settimeout(patience)
    try:
        d = c.recv(100)
        return time.time() - t0, ("eof" if d == b"" else "data")
    except ConnectionResetError:
        return time.time() - t0, "reset"
    except socket.timeout:
        return time.time() - t0, "open"

def within(seconds, limit_ms, slack_ms=300, early_ms=50):
    return (limit_ms - early_ms) / 1000 <= seconds <= (limit_ms + slack_ms) / 1000

# ---------------------------------------------------------------------------------------------- RT-7a and RT-4c

def connect_timeout():
    hole = free_port()
    blackhole = BlackholeBackend(hole)
    good = free_port()
    echo = EchoBackend(good)
    # one target: nothing to retry, so the client is closed when the connect times out
    p1 = free_port()
    s1 = Server([f"127.0.0.1:{p1}"], [f"127.0.0.1:{hole}"], workers=1, stat_ms=200,
                extra=["--connect-timeout-ms", "500"])
    # two targets, the blackhole first: the first connection starts at it, times out, and is retried on the echo
    p2 = free_port()
    s2 = Server([f"127.0.0.1:{p2}"], [f"127.0.0.1:{hole}", f"127.0.0.1:{good}"], workers=1, stat_ms=200,
                extra=["--connect-timeout-ms", "500"])
    try:
        s1.start().wait_ready(); s2.start().wait_ready()
        c = connect(p1, timeout=10)
        c.sendall(b"anybody there?")
        secs, how = timed_close(c)
        c.close()
        t.note(f"RT-7a measured: closed after {secs:.2f}s ({how}) for a 0.5 s connect timeout")
        t.check(how in ("eof", "reset") and within(secs, 500), f"RT-7a a connect that never completes is given up at the connect timeout ({secs:.2f}s, {how}; limit 0.5 s + 0.3 s)")
        t.check(s1.wait_closed("ConnectFailed", lambda v: v == 1, timeout=3) == 1, "RT-7a ... counted as closed by ConnectFailed")
        t.check(s1.wait_stat("connect_failures", lambda v: v == 1, timeout=3) == 1, "RT-7a ... one failed attempt")

        # RT-4c, the timed-out half: the same blackhole first in the list, then a good target.
        payload = os.urandom(100_000)
        t0 = time.time()
        c = connect(p2, timeout=10)
        c.sendall(payload)                                    # at once: it must still arrive intact after the retry
        c.shutdown(socket.SHUT_WR)
        got = bytearray()
        c.settimeout(10)
        while True:
            d = c.recv(65536)
            if not d:
                break
            got += d
        took = time.time() - t0
        c.close()
        t.note(f"RT-4c measured: echoed after {took:.2f}s through [blackhole, echo] with a 0.5 s connect timeout")
        t.check(bytes(got) == payload, "RT-4c a connect that times out is retried on the next target and the client's 100 KB arrives intact and in order")
        t.check(0.45 <= took <= 0.9, f"RT-4c ... after about one connect timeout, not before and not much after ({took:.2f}s)")
        f = s2.wait_stat("connect_failures", lambda v: v >= 1, timeout=3)
        t.check(f == 1 and s2.total("retries") == 1, f"RT-4c connect_failures=1 and retries=1 (saw {f} and {s2.total('retries')})")
        t.check(s1.alive() and s2.alive() and not s1.stderr and not s2.stderr, f"RT-7a the workers are up and silent ({s1.stderr[:1]} {s2.stderr[:1]})")
    finally:
        s1.stop(); s2.stop(); blackhole.stop(); echo.stop()

# ---------------------------------------------------------------------------------------------- RT-7b

def idle_timeout():
    sent = []
    def talker(c):                                            # a backend that sends one byte every 400 ms for 3 s
        for i in range(8):
            c.sendall(b"t")
            time.sleep(0.4)
        return "done"
    bport = free_port(); eport = free_port()
    talk = ThreadedBackend(bport, talker)
    echo = EchoBackend(eport)
    p1, p2 = free_port(), free_port()
    server = Server([], [], workers=1, stat_ms=200, extra=["--idle-timeout-ms", "1000", "--half-close-timeout-ms", "10000",
                    "--route", f"127.0.0.1:{p1}=127.0.0.1:{eport}", "--route", f"127.0.0.1:{p2}=127.0.0.1:{bport}"])
    try:
        server.start().wait_ready()
        # nothing either way
        c = connect(p1, timeout=10)
        secs, how = timed_close(c)
        c.close()
        t.note(f"RT-7b measured: an idle connection closed after {secs:.2f}s for a 1.0 s idle timeout")
        t.check(how in ("eof", "reset") and within(secs, 1000), f"RT-7b a connection with no bytes either way is closed at the idle timeout ({secs:.2f}s, {how})")
        t.check(server.wait_closed("IdleTimeout", lambda v: v == 1, timeout=3) == 1, "RT-7b ... counted as closed by IdleTimeout")
        # client to server traffic every 400 ms keeps it alive for 3 s
        c = connect(p1, timeout=10)
        alive = True
        for i in range(8):
            c.sendall(b"k")
            if recv_exact(c, 1) != b"k":
                alive = False
            time.sleep(0.4)
        t.check(alive, "RT-7b a byte every 400 ms for 3 s keeps a 1 s idle timeout from firing")
        c.close()
        # server to client traffic only
        c = connect(p2, timeout=10)
        got = 0
        c.settimeout(4)
        try:
            while True:
                d = c.recv(10)
                if not d:
                    break
                got += len(d)
        except socket.timeout:
            pass
        c.close()
        t.check(got == 8, f"RT-7b bytes flowing only from the backend also keep the connection open until the backend is done ({got} of 8)")
        t.check(server.closed("IdleTimeout") == 1, f"RT-7b no connection other than the silent one was closed by the idle timeout ({server.closed('IdleTimeout')})")
    finally:
        server.stop(); talk.stop(); echo.stop()

# ---------------------------------------------------------------------------------------------- RT-7c

def half_close_timeout():
    def fin_first(c):                                        # the backend ends its sending side, then waits to be closed
        c.shutdown(socket.SHUT_WR)
        t0 = time.time()
        c.settimeout(6)
        try:
            while c.recv(100):
                pass
        except ConnectionResetError:
            pass
        except socket.timeout:
            return -1.0
        return time.time() - t0                              # seconds from its FIN until the proxy closed the connection
    def trickle(c):                                          # keeps sending after the client's FIN, then closes
        c.settimeout(6)
        for i in range(8):
            c.sendall(b"d")
            time.sleep(0.4)
        return "trickled"
    silent = free_port(); sbk = free_port(); tbk = free_port()
    hold = HoldBackend(silent)                                # accepts and never sends or closes
    first = ThreadedBackend(sbk, fin_first)
    trick = ThreadedBackend(tbk, trickle)
    pa, pb, pc = free_port(), free_port(), free_port()
    server = Server([], [], workers=1, stat_ms=200, extra=["--idle-timeout-ms", "10000", "--half-close-timeout-ms", "1000",
                    "--route", f"127.0.0.1:{pa}=127.0.0.1:{silent}", "--route", f"127.0.0.1:{pb}=127.0.0.1:{sbk}",
                    "--route", f"127.0.0.1:{pc}=127.0.0.1:{tbk}"])
    try:
        server.start().wait_ready()
        # the client ends its side, the backend never does
        c = connect(pa, timeout=10)
        time.sleep(0.2)
        c.shutdown(socket.SHUT_WR)
        secs, how = timed_close(c)
        c.close()
        t.note(f"RT-7c measured: client FIN, backend silent: closed after {secs:.2f}s for a 1.0 s half-close timeout")
        t.check(how in ("eof", "reset") and within(secs, 1000), f"RT-7c a connection the client half-closed and the backend never finishes is closed at the half-close timeout ({secs:.2f}s, {how})")
        t.check(server.wait_closed("HalfCloseTimeout", lambda v: v >= 1, timeout=3) >= 1, "RT-7c ... counted as HalfCloseTimeout")
        # the backend ends its side first, the client stays silent: measured at the backend, from its FIN to the proxy's close
        c = connect(pb, timeout=10)
        r = first.wait_results(1, timeout=6)
        c.close()
        secs = r[0] if r else -1.0
        t.note(f"RT-7c measured: backend FIN, silent client: the proxy closed the connection {secs:.2f}s after the FIN")
        t.check(secs > 0 and within(secs, 1000), f"RT-7c a backend FIN with a silent client: the connection ends at the half-close timeout ({secs:.2f}s from the FIN)")
        t.check(server.wait_closed("HalfCloseTimeout", lambda v: v >= 2, timeout=3) >= 2, "RT-7c ... also counted as HalfCloseTimeout")
        # data still moving in the open direction resets the half-close timer
        c = connect(pc, timeout=10)
        time.sleep(0.2)
        c.shutdown(socket.SHUT_WR)
        got = 0
        c.settimeout(6)
        try:
            while True:
                d = c.recv(10)
                if not d:
                    break
                got += len(d)
        except socket.timeout:
            pass
        c.close()
        t.check(got == 8, f"RT-7c a half-closed connection that is still moving data is not closed by the half-close timer ({got} of 8 bytes)")
        t.check(server.closed("HalfCloseTimeout") == 2, f"RT-7c ... and only the two silent ones were ({server.closed('HalfCloseTimeout')})")
        t.check(server.alive() and not server.stderr, f"RT-7c the worker is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); hold.stop(); first.stop(); trick.stop()

t.run(connect_timeout)
t.run(idle_timeout)
t.run(half_close_timeout)
t.finish()
