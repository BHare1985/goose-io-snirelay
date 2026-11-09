#!/usr/bin/env python3
# Proves: RT-12b   (a request that arrives in pieces is answered exactly as one that arrives whole; also for pipelined requests)
#
#     tests/net/http_split_test.py   (GOOSE=path/to/goose selects the compiler)
#
# examples/http_server, plain TCP. Every request is written in two parts with a pause between them (TCP_NODELAY, so the server gets two
# Data events), split at EVERY byte boundary of the request: inside the method, the target, the version, inside the CRLF CRLF, and (for
# a pipelined pair) at every byte across the join between the first request and the second.
import os, shutil, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("http_split_test", "RT-12b")
host_lock()
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GOOSE = os.environ.get("GOOSE") or os.path.join(ROOT, "goose-kb", "bin", "goose")

def pattern(n):
    return (bytes(range(251)) * (n // 251 + 2))[:n]

def read_n(c, n):
    buf = b""
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d: raise EOFError(f"closed after {len(buf)} of {n} bytes")
        buf += d
    return buf

def response_len(body):          # the server's head for "/N" is fixed in shape; read until the blank line, then the body
    return body

def read_response(c):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(1)
        if not d: raise EOFError("closed inside a head")
        buf += d
    n = int([l for l in buf.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
    return buf.split(b"\r\n")[0], read_n(c, n)

def pieces(c, data, cuts):
    last = 0
    for cut in cuts + [len(data)]:
        c.sendall(data[last:cut]); last = cut
        time.sleep(0.003)

def body():
    out = tempfile.mkdtemp(prefix="tcprouter_split_")
    try:
        exe = os.path.join(out, "http_server")
        r = subprocess.run([GOOSE, "build", "--debug", "-o", exe, os.path.join(ROOT, "examples", "http_server.goose")], capture_output=True, text=True)
        t.check(r.returncode == 0, "RT-12b examples/http_server.goose builds")
        port = free_port()
        proc = subprocess.Popen([exe, "--port", str(port), "--workers", "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(200):
            if not port_is_free(port): break
            time.sleep(0.05)
        try:
            req = b"GET /300 HTTP/1.1\r\nHost: example\r\nUser-Agent: split\r\n\r\n"
            bad = []
            c = connect(port, timeout=10)
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            for cut in range(1, len(req)):                     # one connection, many requests: it must also stay in step
                pieces(c, req, [cut])
                st, b = read_response(c)
                if not (st.startswith(b"HTTP/1.1 200") and b == pattern(300)): bad.append(cut)
            t.check(not bad, f"RT-12b a request split in two at every one of its {len(req) - 1} byte boundaries is answered correctly (bad cuts: {bad})")
            c.close()
            # three pieces: the head cut inside the CRLFCRLF in every possible way
            end = req.index(b"\r\n\r\n")
            bad = []
            for a in range(end, end + 4):
                for b2 in range(a, end + 5):
                    c = connect(port, timeout=10); c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    pieces(c, req, [a] if a == b2 else [a, b2])
                    st, b = read_response(c)
                    if not (st.startswith(b"HTTP/1.1 200") and b == pattern(300)): bad.append((a, b2))
                    c.close()
            t.check(not bad, f"RT-12b the blank line cut at every position, in two or three pieces (bad: {bad})")
            # a pipelined pair, split at every byte across the whole 2-request stream
            pair = b"GET /11 HTTP/1.1\r\nHost: x\r\n\r\nGET /5000 HTTP/1.1\r\nHost: x\r\n\r\n"
            bad = []
            for cut in range(1, len(pair)):
                c = connect(port, timeout=10); c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                pieces(c, pair, [cut])
                s1, b1 = read_response(c); s2, b2 = read_response(c)
                if not (b1 == pattern(11) and b2 == pattern(5000)): bad.append(cut)
                c.close()
            t.check(not bad, f"RT-12b two pipelined requests split at every byte of the stream are both answered, in order (bad cuts: {bad})")
            # a pipelined pair where the second request arrives one byte at a time
            c = connect(port, timeout=10); c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            first = b"GET /11 HTTP/1.1\r\nHost: x\r\n\r\n"; second = b"GET /5000 HTTP/1.1\r\nHost: x\r\n\r\n"
            c.sendall(first + second[:1])
            for k in range(1, len(second)):
                time.sleep(0.002); c.sendall(second[k:k + 1])
            s1, b1 = read_response(c); s2, b2 = read_response(c)
            t.check(b1 == pattern(11) and b2 == pattern(5000), "RT-12b a second request dribbled in one byte at a time behind a whole first one")
            c.close()
            t.check(proc.poll() is None, "RT-12b the server is still running")
        finally:
            proc.terminate()
            try: proc.wait(10)
            except subprocess.TimeoutExpired: proc.kill()
            err = proc.stderr.read()
            t.check(not err.strip(), f"RT-12b the server wrote nothing to stderr ({err.strip()[:200]!r})")
    finally:
        shutil.rmtree(out, ignore_errors=True)

t.run(body)
t.finish()
