#!/usr/bin/env python3
# Proves: RT-13g RT-13h RT-13i RT-13j   (Message.Policy reaches every worker's policy as on_message(body, now_ms) -> Effect, in post order; CloseTagged cuts)
#
#     tests/run_tests.sh policy_message      (builds harness/policy_message_server.goose and sets POLICY_MESSAGE_SERVER)
import os, queue, signal, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("policy_message_test", "RT-13g RT-13h RT-13i RT-13j")
host_lock()
SERVER = os.environ.get("POLICY_MESSAGE_SERVER", "tests/net/harness/policy_message_server")
WORKERS = 3

class Run:
    def __init__(self, backend_port):
        self.port = free_port()
        self.p = subprocess.Popen([SERVER, "--listen", f"127.0.0.1:{self.port}", "--to", f"127.0.0.1:{backend_port}", "--workers", str(WORKERS)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = []
        threading.Thread(target=lambda: [self.lines.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        for _ in range(100):
            if self.lines.count("READY") >= WORKERS: break
            time.sleep(0.05)
    def say(self, text): self.p.stdin.write(text + "\n"); self.p.stdin.flush()
    def wait(self, pred, secs=3):
        end = time.time() + secs
        while time.time() < end:
            if pred(): return True
            time.sleep(0.02)
        return False
    def msgs(self): return [l for l in self.lines if l.startswith("MSG ")]
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()

def echo_backend():
    port = free_port()
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(16)
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

def body():
    bport, bsock = echo_backend()
    r = Run(bport)
    try:
        t.check(r.lines.count("READY") == WORKERS, f"{WORKERS} workers started")
        # RT-13g: every worker gets every message once
        r.say("msg hello")
        ok = r.wait(lambda: len(r.msgs()) >= WORKERS)
        got = r.msgs()
        t.check(ok and len(got) == WORKERS, f"RT-13g one message reaches all {WORKERS} workers ({len(got)} calls)")
        t.check(sorted(l.split()[1] for l in got) == [f"worker={k}" for k in range(WORKERS)] and all("body=hello len=5 now_ok=true" in l.lower() for l in got),
                "RT-13g each worker once, body intact, now_ms passed")
        # RT-13h: post order, and the largest body (48 bytes) intact
        r.lines.clear() if False else None
        before = len(r.msgs())
        big = "x" * 48
        for b in ("m1", "m2", "m3", big):
            r.say("msg " + b)
        r.wait(lambda: len(r.msgs()) >= before + 4 * WORKERS)
        new = r.msgs()[before:]
        for k in range(WORKERS):
            seq = [l.split("body=")[1].split(" len=")[0] for l in new if l.startswith(f"MSG worker={k} ")]
            t.check(seq == ["m1", "m2", "m3", big], f"RT-13h worker {k} sees post order and a 48-byte body intact ({[s[:6] for s in seq]})")
        # RT-13i: CloseTagged from the policy cuts the connection the policy picked (tag 40, gen 7), only that tag
        c = socket.create_connection(("127.0.0.1", r.port), timeout=5)
        c.sendall(b"ping"); c.settimeout(3)
        t.check(c.recv(10) == b"ping", "RT-13i a connection through the policy's pick is served")
        r.say("msg cut")
        c.settimeout(3)
        try: d = c.recv(10)
        except OSError: d = b""
        t.check(d == b"", "RT-13i the policy's Effect.CloseTagged closed the connection")
        t.check(r.wait(lambda: "CLOSED tag=40" in r.lines), "RT-13i and the policy was told it closed")
        c2 = socket.create_connection(("127.0.0.1", r.port), timeout=5)
        c2.sendall(b"pong"); c2.settimeout(3)
        t.check(c2.recv(10) == b"pong", "RT-13i a new connection (not cut) is still served")
        # RT-13j (PX-5): a Stats gather returns only after every earlier Policy message was applied on every worker
        bad = 0
        for k in range(100):
            have = len(r.msgs())
            r.say(f"msg s{k}"); r.say("sync")
            r.wait(lambda: r.lines.count("SYNCED") > k)
            seen_at_sync = sum(1 for l in r.lines[:[i for i, l in enumerate(r.lines) if l == "SYNCED"][k]] if l.startswith("MSG ") and f"body=s{k} " in l)
            if seen_at_sync != WORKERS: bad += 1
        t.check(bad == 0, f"RT-13j after each of 100 'post a Policy message, then gather' the message was already applied on all {WORKERS} workers ({bad} early replies)")
        t.check(r.p.poll() is None, "the program is up")
    finally:
        r.stop(); bsock.close()

t.run(body)
t.finish()
