#!/usr/bin/env python3
# Support check (not a requirement row): does tcprouter give gslib's sans-I/O TLS server what it needs? See docs/tls-support.md.
#
#     tests/net/tls_support_test.py   (GOOSE=path/to/goose selects the compiler)
#
# Builds harness/tls_server.goose, which imports gslib (github.com/SorinS/gslib, pinned to a commit; it is fetched by the compiler into
# ~/.goose/pkg, never vendored here), drives gslib's `tls::server_feed` from handler Data events and answers with `send`. Python's
# `ssl` is the independent client. Needs `openssl` to make a throw-away certificate. Results are printed as the support matrix.
import os, shutil, socket, ssl, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("tls_support_test", "support check")
host_lock()
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GOOSE = os.environ.get("GOOSE") or os.path.join(ROOT, "goose-kb", "bin", "goose")
HOST = "a.test"

def pattern(n):
    block = bytes(range(251))
    return (block * (n // 251 + 2))[:n]

def make_cert(d):
    run = lambda *a: subprocess.run(a, check=True, capture_output=True)
    run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", f"{d}/k.pem", "-out", f"{d}/c.pem",
        "-days", "2", "-subj", f"/CN={HOST}", "-addext", f"subjectAltName=DNS:{HOST}")
    run("openssl", "pkey", "-in", f"{d}/k.pem", "-outform", "DER", "-out", f"{d}/k.der")
    run("openssl", "x509", "-in", f"{d}/c.pem", "-outform", "DER", "-out", f"{d}/c.der")

def client(port, version, name=HOST, cafile=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(cafile)
    ctx.minimum_version = ctx.maximum_version = version
    raw = socket.create_connection(("127.0.0.1", port), timeout=20)
    return ctx.wrap_socket(raw, server_hostname=name)

def get(c, target):
    """One request on a TLS socket; returns (status line, body)."""
    c.sendall(b"GET %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target.encode(), HOST.encode()))
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(65536)
        if not d: raise EOFError("closed inside a head")
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    n = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
    while len(rest) < n:
        d = c.recv(1 << 20)
        if not d: raise EOFError("closed inside a body")
        rest += d
    return head.split(b"\r\n")[0], rest

def body():
    out = tempfile.mkdtemp(prefix="tcprouter_tls_")
    try:
        make_cert(out)
        exe = os.path.join(out, "tls_server")
        r = subprocess.run([GOOSE, "build", "--debug", "-o", exe, os.path.join(ROOT, "tests", "net", "harness", "tls_server.goose")], capture_output=True, text=True)
        t.check(r.returncode == 0 and os.path.exists(exe), f"gslib + tcprouter build together ({(r.stdout + r.stderr).strip()[-300:] if r.returncode else 'ok'})")
        port = free_port()
        proc = subprocess.Popen([exe, "--listen", f"127.0.0.1:{port}", "--tag", "7", "--chain", f"{out}/c.der", "--key", f"{out}/k.der", "--control", "--log-events"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        log = []
        threading.Thread(target=lambda: [log.append(l) for l in proc.stdout], daemon=True).start()
        for _ in range(200):
            if not port_is_free(port): break
            time.sleep(0.05)
        ca = f"{out}/c.pem"
        try:
            for name, version in (("TLS 1.3", ssl.TLSVersion.TLSv1_3), ("TLS 1.2", ssl.TLSVersion.TLSv1_2)):
                c = client(port, version, cafile=ca)
                t.check(c.version() == ("TLSv1.3" if version == ssl.TLSVersion.TLSv1_3 else "TLSv1.2"), f"{name} handshake driven by Data events and send() completes ({c.version()})")
                st, b = get(c, "/")
                t.check(st.startswith(b"HTTP/1.1 200") and b == b"hello\n", f"{name} one HTTP/1.1 request and response")
                ok = all(get(c, f"/{n}")[1] == pattern(n) for n in (11, 20000, 3, 100000))
                t.check(ok, f"{name} keep-alive: four more requests on the same connection, 3 B to 100 kB, bodies exact")
                st, b = get(c, "/sni")
                t.check(b == HOST.encode(), f"{name} the server name the client sent is visible to the server ({b!r})")
                c.close()
            # backpressure: 20 MB to a reader that sleeps; another connection must be served meanwhile
            c = client(port, ssl.TLSVersion.TLSv1_3, cafile=ca)
            c.sendall(b"GET /20000000 HTTP/1.1\r\n\r\n")
            time.sleep(1.0)                                              # the server's queue is full, the client has read nothing
            c2 = client(port, ssl.TLSVersion.TLSv1_2, cafile=ca)
            st, b = get(c2, "/")
            t.note(f"backpressure: second session answered while the first was stalled")
            t.check(b == b"hello\n", "backpressure: while one session's 20 MB response is stalled, another session is served")
            c2.close()
            got = 0; bad = False; head = b""
            while b"\r\n\r\n" not in head: head += c.recv(65536)
            rest = head.split(b"\r\n\r\n", 1)[1]
            want = pattern(20000000)
            while got < 20000000:
                d = rest or c.recv(1 << 20)
                rest = b""
                if not d: break
                if d != want[got:got + len(d)]: bad = True; break
                got += len(d)
                if got % 4000000 < len(d): time.sleep(0.05)
            t.check(got == 20000000 and not bad, f"backpressure: all 20,000,000 bytes arrive in order after the stall ({got})")
            c.close()
            # close: the session is freed when the peer closes mid-response
            c = client(port, ssl.TLSVersion.TLSv1_3, cafile=ca)
            c.sendall(b"GET /50000000 HTTP/1.1\r\n\r\n"); time.sleep(0.3); c.close()
            time.sleep(0.5)
            c = client(port, ssl.TLSVersion.TLSv1_3, cafile=ca)
            st, b = get(c, "/live")
            t.note(f"live sessions after the hang-up: {b!r}")
            t.check(b == b"1", f"close: a peer that hangs up mid-response leaves no session behind (live sessions: {b!r})")
            c.close()
            # fenced: a deadline passes while a TLS session is open and streaming
            c = client(port, ssl.TLSVersion.TLSv1_3, cafile=ca)
            c.sendall(b"GET /200000000 HTTP/1.1\r\n\r\n")
            until = boottime_ms() + 800
            proc.stdin.write(f"deadline 7 {until}\n"); proc.stdin.flush()
            arrivals = []
            c.settimeout(10)
            while True:
                try:
                    d = c.recv(1 << 20)
                except (OSError, ssl.SSLError):
                    break
                if not d: break
                arrivals.append((boottime_ms(), len(d)))
            t.note(f"fence: {len(arrivals)} reads, {sum(n for _, n in arrivals)} bytes before the deadline, last read {(arrivals[-1][0] - until) if arrivals else None} ms from it")
            late = sum(n for at, n in arrivals if at > until + 100)
            t.check(late == 0 and boottime_ms() > until, f"fenced: no TLS bytes reach the client after the deadline ({late} late bytes, {sum(n for _, n in arrivals)} before)")
            time.sleep(0.3)
            t.check(any("Fenced" in l for l in log), "fenced: the session is closed as Fenced")
        finally:
            proc.terminate()
            try: proc.wait(10)
            except subprocess.TimeoutExpired: proc.kill()
    finally:
        shutil.rmtree(out, ignore_errors=True)

t.run(body)
t.finish()
