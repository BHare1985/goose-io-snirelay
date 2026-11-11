#!/usr/bin/env python3
# Proves: RT-10c   (Message.SetAddr changes one address of a target on every worker; the wider message stays atomic)
#
#     tests/net/set_addr_test.py
#
# Why: tcpproxy must add, replace and remove a backend while running (verify_backends.py t_control_managed: `add app 127.0.0.1:18501`, then
# the same address again = no-op, then connections reach it). Workers share nothing, so the change travels as a message. An Addr is
# 48 bytes, tcprouter's Message is 16, so the message grows to 64 bytes (sockaddr_in6 is 28) and a pipe write of up to PIPE_BUF stays
# atomic, which keeps "every worker receives each message once" (RT-10a).
#
# The harness: forward_server --control gains
#     set-addr TARGET SLOT HOST:PORT        posts Message.SetAddr { target, slot, <the address> }; HOST may be an IPv6 literal [::1]
#     set-addr TARGET SLOT -                the same with the slot cleared (it is never picked again)
# TARGET is the index in Config.targets (a single --route makes target 0); SLOT is a position in that target's addrs (0 to 7). A SLOT
# past the end appends: slots up to it that were never set stay cleared. Out-of-range or unparsable arguments are ignored (a worker
# never aborts on a message). Today the server ignores the unknown verb, so every scenario that needs a change fails: the red.
import os, socket, sys, time, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("set_addr_test", "RT-10c")
host_lock()

class V6Echo:
    """A thread-per-connection echo on ::1 that counts accepts (netlib's backends are IPv4 only)."""
    def __init__(self, port):
        self.port, self.accepted = port, 0
        self.sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("::1", port)); self.sock.listen(64)
        threading.Thread(target=self._loop, daemon=True).start()
    def _loop(self):
        while True:
            try: c, _ = self.sock.accept()
            except OSError: return
            self.accepted += 1
            threading.Thread(target=self._echo, args=(c,), daemon=True).start()
    def _echo(self, c):
        try:
            while (d := c.recv(4096)): c.sendall(d)
        except OSError: pass
        c.close()
    def stop(self): self.sock.close()

def echo_through(port, payload=b"hello", host="127.0.0.1"):
    try:
        c = connect(port, host=host, timeout=5)
        c.sendall(payload)
        got = recv_exact(c, len(payload))
        c.close()
        return got == payload
    except (OSError, EOFError):
        return False

def rig(slots, workers=4, host="127.0.0.1"):
    """A server with one route (target 0) whose slots are the given 'host:port' strings."""
    pport = free_port()
    server = Server([], [], workers=workers, stat_ms=200, nofile=8192,
                    extra=["--control"], routes=[(f"127.0.0.1:{pport}", slots)])
    return server, pport

def replace_reaches_every_worker():
    a, b = EchoBackend(free_port()), EchoBackend(free_port())
    server, pport = rig([f"127.0.0.1:{a.port}"])
    try:
        server.start().wait_ready()
        old = connect(pport)
        old.sendall(b"first"); recv_exact(old, 5)
        for _ in range(40): echo_through(pport)
        t.check(a.accepted >= 41 and b.accepted == 0, f"RT-10c before: everything goes to A ({a.accepted}) and nothing to B ({b.accepted})")
        server.command(f"set-addr 0 0 127.0.0.1:{b.port}")
        time.sleep(0.3)
        a_before = a.accepted
        ok = sum(1 for _ in range(200) if echo_through(pport))
        t.check(ok == 200, f"RT-10c after a replace, 200 new connections are echoed ({ok}/200)")
        t.check(a.accepted == a_before, f"RT-10c none of them reached the old address, so each of the 4 workers got the message ({a.accepted - a_before} did)")
        t.check(b.accepted >= 200, f"RT-10c all of them reached the new address ({b.accepted})")
        old.sendall(b"again")
        t.check(recv_exact(old, 5) == b"again", "RT-10c an open connection to the old address is not touched")
        d = server.totals()
        t.check(d["accepted"] >= 241, f"RT-10c gather_stats still sums the 4 workers after the change ({d['accepted']})")
    finally:
        server.stop(); a.stop(); b.stop()

def refused_then_fixed():
    b = EchoBackend(free_port())
    server, pport = rig([f"127.0.0.1:{free_port()}"], workers=2)
    try:
        server.start().wait_ready()
        t.check(not echo_through(pport), "RT-10c a refused address: the client is closed")
        server.command(f"set-addr 0 0 127.0.0.1:{b.port}")
        time.sleep(0.3)
        t.check(all(echo_through(pport) for _ in range(20)), "RT-10c after the address is fixed by message, connections work (no restart)")
    finally:
        server.stop(); b.stop()

def append_and_clear():
    a, b = EchoBackend(free_port()), EchoBackend(free_port())
    server, pport = rig([f"127.0.0.1:{a.port}"], workers=1)
    try:
        server.start().wait_ready()
        server.command(f"set-addr 0 1 127.0.0.1:{b.port}")              # add: one past the end appends
        time.sleep(0.3)
        for _ in range(40): echo_through(pport)
        t.check(a.accepted > 5 and b.accepted > 5, f"RT-10c an appended address joins the rotation (A {a.accepted}, B {b.accepted})")
        server.command("set-addr 0 0 -")                                  # del
        time.sleep(0.3)
        a_before, b_before = a.accepted, b.accepted
        ok = sum(1 for _ in range(30) if echo_through(pport))
        t.check(ok == 30 and a.accepted == a_before and b.accepted == b_before + 30, f"RT-10c a cleared slot is never picked: 30 of 30 echoed, all to B (A +{a.accepted - a_before}, B +{b.accepted - b_before})")
        server.command("set-addr 0 1 -")                                  # nothing left
        time.sleep(0.3)
        t.check(not echo_through(pport), "RT-10c with every slot cleared the client is closed, not hung")
        t.check(server.alive() and not server.stderr, f"RT-10c the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); a.stop(); b.stop()

def ipv6_address():
    if not has_ipv6():
        t.skip("RT-10c IPv6 address in a message", "no IPv6 loopback here"); return
    v4 = EchoBackend(free_port())
    v6 = V6Echo(free_port())
    server, pport = rig([f"127.0.0.1:{v4.port}"], workers=2)
    try:
        server.start().wait_ready()
        server.command(f"set-addr 0 0 [::1]:{v6.port}")
        time.sleep(0.3)
        ok = sum(1 for _ in range(20) if echo_through(pport))
        t.check(ok == 20 and v6.accepted >= 20, f"RT-10c an IPv6 address (the 28-byte sockaddr) arrives whole ({ok}/20 echoed, {v6.accepted} on ::1)")
    finally:
        server.stop(); v4.stop(); v6.stop()

def no_tearing():
    a, b = EchoBackend(free_port()), EchoBackend(free_port())
    server, pport = rig([f"127.0.0.1:{a.port}"])
    try:
        server.start().wait_ready()
        stop = threading.Event()
        def flip():
            i = 0
            while not stop.is_set():
                server.command(f"set-addr 0 0 127.0.0.1:{(a if i % 2 == 0 else b).port}")
                i += 1
        th = threading.Thread(target=flip, daemon=True); th.start()
        ok = sum(1 for _ in range(300) if echo_through(pport))
        stop.set(); th.join(2)
        time.sleep(0.3)
        t.check(ok == 300, f"RT-10c 300 connections made while the address flips A/B as fast as it can be posted: every one echoed ({ok}/300)")
        t.check(server.wait_stat("connect_failures", lambda v: v == 0, timeout=1) == 0, f"RT-10c no connect failed: no worker ever saw a half-written or mixed address ({server.total('connect_failures')})")
        t.check(server.alive() and not server.stderr, f"RT-10c the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); a.stop(); b.stop()

def bad_arguments():
    a = EchoBackend(free_port())
    server, pport = rig([f"127.0.0.1:{a.port}"], workers=2)
    try:
        server.start().wait_ready()
        for bad in ("9 0 127.0.0.1:1", "0 99 127.0.0.1:1", "0 0 not-an-address", "0 0 127.0.0.1:0", "-1 0 127.0.0.1:1", "0 0"):
            server.command("set-addr " + bad)
        time.sleep(0.3)
        t.check(server.alive() and not server.stderr, f"RT-10c bad target, slot or address are ignored: the program is up and silent ({server.stderr[:2]})")
        t.check(all(echo_through(pport) for _ in range(20)) and a.accepted >= 20, "RT-10c and slot 0 is unchanged: still served by A")
    finally:
        server.stop(); a.stop()

t.run(replace_reaches_every_worker)
t.run(refused_then_fixed)
t.run(append_and_clear)
t.run(ipv6_address)
t.run(no_tearing)
t.run(bad_arguments)
t.finish()
