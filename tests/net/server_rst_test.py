#!/usr/bin/env python3
# Proves: RT-20a RT-20b   (a backend that answers and then aborts: the bytes it sent before the RST still reach the client)
#
# Why: Linux keeps data that arrived before an RST readable. A server that closes with unread request bytes in its receive queue sends an RST
# right after its response, so "response then RST" is common. The proxy is frozen (SIGSTOP) while the backend answers and aborts, so the data and the
# RST are queued together when it resumes: the engine used to close on EPOLLERR before reading, and the response was lost.
#     tests/run_tests.sh server_rst
import os, signal, socket, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("server_rst_test", "RT-20a RT-20b")
host_lock()

def body():
    for label, payload in (("small", b"RESPONSE"), ("larger than one buffer", bytes(range(251)) * 400)):
        backend = socket.socket(); backend.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        backend.bind(("127.0.0.1", 0)); backend.listen(4)
        bport = backend.getsockname()[1]
        pport = free_port()
        server = Server([f"127.0.0.1:{pport}"], [f"127.0.0.1:{bport}"], workers=1, extra=["--control"])
        try:
            server.start().wait_ready()
            c = socket.create_connection(("127.0.0.1", pport), timeout=5)
            c.sendall(b"req")
            b, _ = backend.accept(); b.settimeout(3)
            assert b.recv(10) == b"req"
            server.proc.send_signal(signal.SIGSTOP)
            try:
                b.sendall(payload)
                b.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                b.close()                                              # data, then RST
                time.sleep(0.3)
            finally:
                server.proc.send_signal(signal.SIGCONT)
            got = b""
            c.settimeout(3)
            try:
                while True:
                    d = c.recv(1 << 20)
                    if not d: break
                    got += d
            except (socket.timeout, OSError): pass
            t.check(got == payload, f"RT-20a ({label}) the bytes the backend sent before its RST reach the client ({len(got)} of {len(payload)})")
            time.sleep(0.3)
            tot = server.totals()
            t.check(tot["open"] == 0, f"RT-20b ({label}) the connection is closed afterwards ({tot['open']} open)")
            c.close()
        finally:
            server.stop(); backend.close()

t.run(body)
t.finish()
