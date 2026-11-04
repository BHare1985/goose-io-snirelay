#!/usr/bin/env python3
# Proves: RT-9b RT-11a   (examples/http_hello serves 100,000 keep-alive requests from 100 clients with no errors;
#                         the three examples build)
#
#     tests/net/examples_test.py          (GOOSE=path/to/goose selects the compiler; run_tests.sh sets it)
#
# The examples are the code a stranger reads first, so the test builds each exactly as a user would
# (`goose build examples/NAME.goose`) and then uses http_hello as a real HTTP server.
import os, shutil, socket, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GOOSE = os.environ.get("GOOSE") or (os.path.join(ROOT, "goose-kb", "bin", "goose") if os.path.exists(os.path.join(ROOT, "goose-kb", "bin", "goose")) else "goose")
t = Test("examples_test", "RT-9b RT-11a")
host_lock()

RESPONSE = b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nContent-Type: text/plain\r\n\r\nhello\n"
REQUEST = b"GET /%d HTTP/1.1\r\nHost: example\r\nUser-Agent: examples_test\r\n\r\n"

def build_examples(out):
    for name in ("forward_port", "sni_router", "http_hello"):
        exe = os.path.join(out, name)
        r = subprocess.run([GOOSE, "build", "--debug", "-o", exe, os.path.join(ROOT, "examples", name + ".goose")],
                           capture_output=True, text=True)
        t.check(r.returncode == 0 and os.path.exists(exe), f"RT-11a examples/{name}.goose builds ({(r.stdout + r.stderr).strip()[-300:] if r.returncode else 'ok'})")

def read_response(c):
    return recv_exact(c, len(RESPONSE))

def load(port, out):
    clients, per = 100, 1000
    errors = []
    def client(i):
        c = connect(port, timeout=30)
        for k in range(per):
            c.sendall(REQUEST % (i * per + k))
            if read_response(c) != RESPONSE:
                errors.append((i, k, "wrong response"))
                return
        c.close()
    t0 = time.time()
    results = run_threads([lambda i=i: client(i) for i in range(clients)])
    took = time.time() - t0
    failed = [r for r in results if isinstance(r, Exception)]
    t.note(f"RT-9b measured: {clients * per} requests from {clients} keep-alive clients in {took:.1f}s = {clients * per / took:.0f} requests/s")
    t.check(not failed and not errors, f"RT-9b 100,000 requests from 100 clients, every response byte-exact, 0 errors ({len(failed)} client failures, {len(errors)} wrong responses; {failed[:1]})")

def split_and_pipelined(port):
    # A request head cut at every position: the server must wait for the rest and answer once.
    bad = 0
    head = REQUEST % 7
    for cut in range(1, len(head)):
        c = connect(port, timeout=10)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        c.sendall(head[:cut])
        time.sleep(0.002)
        c.sendall(head[cut:])
        try:
            if read_response(c) != RESPONSE:
                bad += 1
        except (EOFError, OSError):
            bad += 1
        c.close()
    t.check(bad == 0, f"RT-9b a request head cut at each of its {len(head) - 1} positions is answered once, correctly ({bad} bad)")
    c = connect(port, timeout=10)
    c.sendall((REQUEST % 1) + (REQUEST % 2))
    both = recv_exact(c, 2 * len(RESPONSE))
    c.sendall((REQUEST % 3)[:20])
    time.sleep(0.05)
    c.sendall((REQUEST % 3)[20:] + (REQUEST % 4))
    more = recv_exact(c, 2 * len(RESPONSE))
    c.close()
    t.check(both == RESPONSE * 2 and more == RESPONSE * 2, "RT-9b two pipelined requests in one write, and a split one followed by another, are all answered in order")
    # An oversized head is refused without hurting the worker.
    c = connect(port, timeout=10)
    try:
        c.sendall(b"GET / HTTP/1.1\r\nX: " + b"a" * 5000)
        d = c.recv(10)
        closed = d == b""
    except (ConnectionResetError, BrokenPipeError):
        closed = True
    c.close()
    t.check(closed, "RT-9b a request head over 2 KB makes the server drop that connection")

def body():
    out = tempfile.mkdtemp(prefix="tcprouter_examples_")
    try:
        build_examples(out)
        port = free_port()
        proc = subprocess.Popen([os.path.join(out, "http_hello"), str(port)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(100):
                if not port_is_free(port):
                    break
                time.sleep(0.05)
            t.check(proc.poll() is None, "RT-9b http_hello is running")
            split_and_pipelined(port)
            load(port, out)
            t.check(proc.poll() is None, "RT-9b http_hello is still running after the load")
        finally:
            proc.terminate()
            try: proc.wait(5)
            except subprocess.TimeoutExpired: proc.kill()
            err = proc.stderr.read()
            t.check(not err.strip(), f"RT-9b http_hello wrote nothing to stderr ({err.strip()[:200]!r})")
    finally:
        shutil.rmtree(out, ignore_errors=True)

t.run(body)
t.finish()
