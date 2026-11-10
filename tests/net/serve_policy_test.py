#!/usr/bin/env python3
# Proves: the policy hook (new tcprouter row, number for Charlie to assign): the engine asks the policy where to
# connect, tells it about failures, successes and closes, and obeys its answers, in forward mode, before any client byte
# is consumed.
#
#     tests/run_tests.sh serve_policy      (builds harness/policy_server.goose and sets POLICY_SERVER)
#
# Each scenario starts the server with three addresses (slot 0, 1, 2) and reads the hook lines it prints. The test double
# picks the highest untried slot first, tag = 40 + slot, gen = 7. The built-in rotation would start at slot 0, so a pass
# means the policy, not Config.targets, chose.
import os, queue, signal, socket, subprocess, sys, threading, time

SERVER = os.environ.get("POLICY_SERVER", "tests/net/harness/policy_server")
failures = 0

def check(ok, what):
    global failures
    print(("ok    " if ok else "FAIL  ") + what)
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

class Server:
    def __init__(self, targets, *extra):
        self.port = free_port()
        args = [SERVER, "--listen", f"127.0.0.1:{self.port}"] + [x for t in targets for x in ("--to", f"127.0.0.1:{t}")] + list(extra)
        self.p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        threading.Thread(target=lambda: [self.lines.put(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        self.expect("READY")
    def next(self, timeout=3):
        try: return self.lines.get(timeout=timeout)
        except queue.Empty: return None
    def expect(self, line):
        got = self.next()
        check(got == line, f"hook line: {line!r} (got {got!r})")
    def expect_prefix(self, prefix):
        got = self.next()
        check(got is not None and got.startswith(prefix), f"hook line starts {prefix!r} (got {got!r})")
    def stop(self):
        self.p.send_signal(signal.SIGTERM)
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def echo_once(port, payload=b"hello"):
    c = socket.create_connection(("127.0.0.1", port), timeout=5)
    c.sendall(payload)
    got = c.recv(100)
    c.close()
    return got

def closed_without_data(port):
    c = socket.create_connection(("127.0.0.1", port), timeout=5)
    c.sendall(b"hello?")
    try: d = c.recv(10)
    except OSError: d = b""
    c.close()
    return d == b""

def refused(): return free_port()

def scenario_policy_chooses():
    print("-- the policy, not Config.targets rotation, chooses: slots [refused, refused, good]")
    e = Echo(); s = Server([refused(), refused(), e.port])
    try:
        check(echo_once(s.port) == b"hello", "client is echoed through the policy's pick")
        s.expect("PICK route=0 tried=0 -> slot=2 tag=42 gen=7")
        s.expect("CONNECTED tag=42")
        s.expect("CLOSED tag=42")
    finally: s.stop()

def scenario_retry_walks_the_policy():
    print("-- failures are reported and the retry is the policy's next pick: slots [good, refused, refused]")
    e = Echo(); s = Server([e.port, refused(), refused()])
    try:
        check(echo_once(s.port) == b"hello", "client is echoed after two refused connects")
        s.expect("PICK route=0 tried=0 -> slot=2 tag=42 gen=7")
        s.expect("CONNECT_FAILED slot=2 tag=42 tried=4")
        s.expect("PICK route=0 tried=4 -> slot=1 tag=41 gen=7")
        s.expect("CONNECT_FAILED slot=1 tag=41 tried=6")
        s.expect("PICK route=0 tried=6 -> slot=0 tag=40 gen=7")
        s.expect("CONNECTED tag=40")
        s.expect("CLOSED tag=40")
    finally: s.stop()

def scenario_give_up_veto():
    print("-- the policy may give up while addresses remain: --max-tries 1, slots [good, good, refused]")
    e = Echo(); s = Server([e.port, e.port, refused()], "--max-tries", "1")
    try:
        check(closed_without_data(s.port), "client is closed: the policy said GiveUp after one failure")
        s.expect("PICK route=0 tried=0 -> slot=2 tag=42 gen=7")
        s.expect("CONNECT_FAILED slot=2 tag=42 tried=4")
        got = s.next(timeout=1)
        check(got is None, f"no further PICK after GiveUp (got {got!r})")
    finally: s.stop()

def scenario_none_closes():
    print("-- Pick.None closes the client: all three refused")
    s = Server([refused(), refused(), refused()])
    try:
        check(closed_without_data(s.port), "client is closed when the policy has nothing to offer")
        for want in ("PICK route=0 tried=0 -> slot=2 tag=42 gen=7", "CONNECT_FAILED slot=2 tag=42 tried=4",
                     "PICK route=0 tried=4 -> slot=1 tag=41 gen=7", "CONNECT_FAILED slot=1 tag=41 tried=6",
                     "PICK route=0 tried=6 -> slot=0 tag=40 gen=7", "CONNECT_FAILED slot=0 tag=40 tried=7",
                     "PICK route=0 tried=7 -> none"):
            s.expect(want)
    finally: s.stop()

for f in (scenario_policy_chooses, scenario_retry_walks_the_policy, scenario_give_up_veto, scenario_none_closes):
    try: f()
    except Exception as ex:
        check(False, f"{f.__name__} raised {ex!r}")
print("FAIL" if failures else "PASS", failures, "failures")
sys.exit(1 if failures else 0)
