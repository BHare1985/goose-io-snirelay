#!/usr/bin/env python3
# Proves: RT-6g   (a deadline table that is full fails closed: a tag that cannot be recorded is fenced, never silently unfenced)
#
#     tests/net/tag_overflow_test.py
#
# Each worker keeps 64 per-tag deadlines. A tag with no entry is normally unfenced, so a deadline that could not be stored used to be dropped
# and left its tag unfenced (found by Bryan, 2026-11-11). Now a full table fences every tag that has no entry. The test fills the table with 64
# tags, then posts a deadline for tag 8 (65th) and checks that tag 8 is refused while tag 7, which has an entry, still serves.
import os, socket, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("tag_overflow_test", "RT-6g")
host_lock()

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

def body():
    back = ThreadedBackend(free_port(), lambda c: [c.sendall(d) for d in iter(lambda: c.recv(4096), b"")])
    ports = {k: free_port() for k in "AC"}
    server = Server([], [], workers=2, stat_ms=200, extra=["--control",
             "--tagged-route", f"127.0.0.1:{ports['A']}=127.0.0.1:{back.port}@7:1",
             "--tagged-route", f"127.0.0.1:{ports['C']}=127.0.0.1:{back.port}@8:1"])
    try:
        server.start().wait_ready()
        far = boottime_ms() + 600000
        t.check(works(connect(ports["C"], timeout=5)), "tag 8 has no entry and is served (the default)")
        server.command(f"deadline 7 {far}")
        for tag in range(100, 163):                                   # 63 more entries: the table (64) is now full
            server.command(f"deadline {tag} {far}")
        time.sleep(0.5)
        t.check(works(connect(ports["A"], timeout=5)), "tag 7 has an entry and is served")
        server.command(f"deadline 8 {far}")                           # the 65th tag: cannot be recorded
        time.sleep(0.5)
        refused = not works(connect(ports["C"], timeout=5))
        t.check(refused, "RT-6g the 65th tag, whose deadline could not be stored, is refused (fail closed)")
        t.check(works(connect(ports["A"], timeout=5)), "tag 7 (has an entry) is unaffected")
        t.check(server.alive() and not server.stderr, f"the program is up and silent ({server.stderr[:2]})")
    finally:
        server.stop(); back.stop()

t.run(body)
t.finish()
