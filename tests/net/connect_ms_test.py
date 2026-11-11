#!/usr/bin/env python3
# Proves: RT-13k (number for Charlie): Pick.To.connect_ms is the connect timeout of that connect; 0 means Limits.connect_timeout_ms
#
#     goose build --debug tests/net/harness/connect_ms_server.goose
#     CONNECT_MS_SERVER=tests/net/harness/connect_ms_server python3 tests/net/connect_ms_test.py
#
# Why: the C proxy has --backup-connect-timeout: a backup is a peer over a WAN, where one lost SYN costs a 1 s retransmit, so its connect wants longer
# than a local server's (verify_backends t_backup_connect_timeout: 200 ms local, 1200 ms backup). The engine has one timer per connection; the pick
# now says which value applies to this connect.
#
# A connect that hangs without failing: a listener with backlog 0 whose queue is already full. The kernel drops further SYNs, so a client's connect
# neither completes nor is refused. Each scenario has two addresses: slot 0 a working echo, slot 1 the hanging one. The test double picks slot 1 first,
# so the time until the client is echoed through slot 0 is, to the millisecond, the timeout slot 1's pick was given plus the work of a second connect.
import os, queue, signal, socket, subprocess, sys, threading, time

SERVER = os.environ.get("CONNECT_MS_SERVER", "tests/net/harness/connect_ms_server")
failures = 0

def check(ok, what):
    global failures
    print(("ok    " if ok else "FAIL  ") + what, flush=True)
    if not ok: failures += 1

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

class Echo:
    def __init__(self):
        self.port = free_port()
        self.sock = socket.socket(); self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port)); self.sock.listen(16)
        threading.Thread(target=self.loop, daemon=True).start()
    def loop(self):
        while True:
            try: c, _ = self.sock.accept()
            except OSError: return
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()
    def serve(self, c):
        try:
            while (d := c.recv(4096)): c.sendall(d)
        except OSError: pass
        c.close()

class Hanging:
    """A listener whose accept queue is full: connects to it hang (SYNs are dropped) until the test ends."""
    def __init__(self):
        self.sock = socket.socket(); self.sock.bind(("127.0.0.1", 0)); self.sock.listen(0)
        self.port = self.sock.getsockname()[1]
        self.fill = []
        for _ in range(4):
            c = socket.socket(); c.setblocking(False)
            try: c.connect(("127.0.0.1", self.port))
            except BlockingIOError: pass
            self.fill.append(c)
        time.sleep(0.2)
        probe = socket.socket(); probe.settimeout(0.5)
        try:
            probe.connect(("127.0.0.1", self.port)); self.works = False
        except socket.timeout:
            self.works = True
        except OSError:
            self.works = False
        probe.close()

class Server:
    def __init__(self, good, hanging, *extra):
        self.port = free_port()
        args = [SERVER, "--listen", f"127.0.0.1:{self.port}", "--to", f"127.0.0.1:{good}", "--to", f"127.0.0.1:{hanging}"] + list(extra)
        self.p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        threading.Thread(target=lambda: [self.lines.put(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        self.next()
    def next(self, timeout=3):
        try: return self.lines.get(timeout=timeout)
        except queue.Empty: return None
    def stop(self):
        self.p.send_signal(signal.SIGTERM)
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def echo_time(port):
    """Seconds until a client is echoed through the proxy (or None if it never was, within 6 s)."""
    t0 = time.time()
    c = socket.create_connection(("127.0.0.1", port), timeout=6)
    c.sendall(b"hello")
    try:
        got = c.recv(10)
    except OSError:
        got = b""
    c.close()
    return time.time() - t0 if got == b"hello" else None

def scenario(name, extra, lo, hi, failed_line):
    print(f"-- {name}", flush=True)
    e = Echo(); h = Hanging()
    if not h.works:
        check(False, "the hanging listener hangs (the host may drop SYNs differently)"); return
    s = Server(e.port, h.port, *extra)
    try:
        took = echo_time(s.port)
        check(took is not None and lo <= took <= hi, f"{name}: the client is echoed through the good address after {None if took is None else round(took, 2)} s (want {lo} to {hi})")
        lines = []
        while True:
            l = s.next(timeout=0.3)
            if l is None: break
            lines.append(l)
        check(any(l.startswith("PICK") and "slot=1" in l and failed_line in l for l in lines), f"{name}: the pick of the hanging slot carried {failed_line!r} ({[l for l in lines if 'slot=1' in l and l.startswith('PICK')]})")
        check(any(l.startswith("CONNECT_FAILED slot=1") for l in lines), f"{name}: the hanging connect was reported failed")
        check(any(l.startswith("CONNECTED tag=40") for l in lines), f"{name}: and the good address was connected")
    finally:
        s.stop()

# the default is long (3 s) in the first scenario, so only the pick's own value can explain a fast failover
scenario("a pick's own timeout (300 ms) beats a long default (3000 ms)", ["--connect-timeout-ms", "3000", "--connect-ms", "1=300"], 0.25, 1.2, "connect_ms=300")
# and the default is short (300 ms) in the second, so only the pick's own value can explain a slow one
scenario("a pick's own timeout (1200 ms) beats a short default (300 ms)", ["--connect-timeout-ms", "300", "--connect-ms", "1=1200"], 1.15, 2.5, "connect_ms=1200")
# 0 is "no opinion": the default applies
scenario("connect_ms 0 uses Limits.connect_timeout_ms (700 ms)", ["--connect-timeout-ms", "700"], 0.6, 1.6, "connect_ms=0")
print("FAIL" if failures else "PASS", failures, "failures")
sys.exit(1 if failures else 0)
