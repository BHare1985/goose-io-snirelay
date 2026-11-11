#!/usr/bin/env python3
# Proves: RT-8d RT-8e   (wait_for_signal() returns the signal number, SIGUSR1 included; drain(deadline_ms) returns how many open sessions it closed at the deadline)
#
#     tests/run_tests.sh signal      (builds harness/signal_server.goose and sets SIGNAL_SERVER)
import os, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("signal_test", "RT-8d RT-8e")
host_lock()
SERVER = os.environ.get("SIGNAL_SERVER", "tests/net/harness/signal_server")

def echo_backend():
    port = free_port()
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(64)
    def serve(c):
        try:
            while (d := c.recv(4096)): c.sendall(d)
        except OSError: pass
        c.close()
    def loop():
        while True:
            try: c, _ = s.accept()
            except OSError: return
            threading.Thread(target=serve, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return port, s

class Run:
    def __init__(self, bport, deadline=500):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}", "--to", f"127.0.0.1:{bport}", "--deadline", str(deadline)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if "READY" in self.lines: break
            time.sleep(0.05)
        time.sleep(0.2)
    def open(self, n):
        cs = []
        for _ in range(n):
            c = socket.create_connection(("127.0.0.1", self.port), timeout=5); c.sendall(b"hi"); c.recv(10); cs.append(c)
        return cs
    def line(self, prefix, secs=5):
        end = time.time() + secs
        while time.time() < end:
            for l in self.lines:
                if l.startswith(prefix): return l
            time.sleep(0.02)
        return None
    def stop(self):
        try: self.p.kill()
        except Exception: pass

def body():
    bport, bsock = echo_backend()
    try:
        for sig, name, num in ((signal.SIGTERM, "SIGTERM", 15), (signal.SIGINT, "SIGINT", 2), (signal.SIGUSR1, "SIGUSR1", 10)):
            r = Run(bport)
            try:
                r.p.send_signal(sig)
                t.check(r.line("SIGNAL") == f"SIGNAL {num}", f"RT-8d wait_for_signal returns {num} for {name} ({r.line('SIGNAL', 0.1)})")
                t.check(r.line("DRAINED") == "DRAINED 0", f"RT-8e {name} with no open session: drain returns 0 ({r.line('DRAINED', 0.1)})")
                try: r.p.wait(5)
                except subprocess.TimeoutExpired: pass
                t.check(r.p.poll() == 0, f"{name}: the program exited by itself ({r.p.poll()})")
            finally: r.stop()
        # sessions still open at the deadline are closed and counted
        r = Run(bport, deadline=500)
        try:
            cs = r.open(3)
            r.p.send_signal(signal.SIGUSR1)
            t0 = time.time()
            t.check(r.line("DRAINED", 6) == "DRAINED 3", f"RT-8e 3 idle sessions at a 500 ms deadline: drain returns 3 ({r.line('DRAINED', 0.1)})")
            t.check(0.4 <= time.time() - t0 <= 2.5, f"RT-8e and it waited for the deadline ({time.time() - t0:.2f} s)")
        finally: r.stop()
        # sessions that end during the drain are not counted
        r = Run(bport, deadline=3000)
        try:
            cs = r.open(2)
            r.p.send_signal(signal.SIGUSR1)
            time.sleep(0.3)
            for c in cs: c.close()
            t.check(r.line("DRAINED", 6) == "DRAINED 0", f"RT-8e sessions that ended before the deadline: drain returns 0 ({r.line('DRAINED', 0.1)})")
        finally: r.stop()
    finally:
        bsock.close()

t.run(body)
t.finish()
