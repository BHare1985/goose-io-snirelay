#!/usr/bin/env python3
# Proves: RT-12a RT-12b RT-12c RT-12d RT-12e   (examples/http_server: the HTTP/1.1 server written on handler mode that the
#                                               benchmarking guides use; its behaviour is that of bench/backend.c)
#
#     tests/net/http_server_test.py          (GOOSE=path/to/goose selects the compiler; run_tests.sh sets it)
#
# The server is built exactly as a user would (`goose build examples/http_server.goose`) and driven by independent Python
# clients over real sockets. Every body is checked byte for byte: body[i] = i % 251.
import os, shutil, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GOOSE = os.environ.get("GOOSE") or (os.path.join(ROOT, "goose-kb", "bin", "goose") if os.path.exists(os.path.join(ROOT, "goose-kb", "bin", "goose")) else "goose")
t = Test("http_server_test", "RT-12a RT-12b RT-12c RT-12d RT-12e")
host_lock()

def pattern(n, start=0):
    block = bytes(i % 251 for i in range(251))
    reps = (start % 251 + n) // 251 + 2
    return (block * reps)[start % 251:start % 251 + n]

_LEFT = {}

def read_response(c, expect_body=True):
    """Reads one response: returns (status line, headers dict, body). The server must send exact Content-Length."""
    buf = _LEFT.pop(c.fileno(), b"")          # bytes of a pipelined next response read earlier
    while b"\r\n\r\n" not in buf:
        d = c.recv(65536)
        if not d:
            raise EOFError(f"closed inside a head ({buf[:80]!r})")
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    headers = {}
    for l in lines[1:]:
        k, v = l.split(b":", 1)
        headers[k.strip().lower()] = v.strip()
    n = int(headers.get(b"content-length", b"0")) if expect_body else 0
    while len(rest) < n:
        d = c.recv(1 << 20)
        if not d:
            raise EOFError("closed inside a body")
        rest += d
    if len(rest) > n:
        _LEFT[c.fileno()] = rest[n:]
        rest = rest[:n]
    return lines[0], headers, rest

def one(port, request, expect_body=True):
    c = connect(port, timeout=20)
    c.sendall(request)
    try:
        return read_response(c, expect_body)
    finally:
        c.close()

def closed_after(c, within=3):
    c.settimeout(within)
    try:
        return c.recv(10) == b""
    except ConnectionResetError:
        return True
    except socket.timeout:
        return False

def rt12a(port):
    st, h, b = one(port, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    t.check(st == b"HTTP/1.1 200 OK" and b == pattern(11) and h[b"content-length"] == b"11", "RT-12a GET / is a 200 with the 11-byte pattern")
    for n in (0, 1, 250, 251, 252, 4096, 16383, 16384, 16385, 32768, 65536, 100000, 1 << 20, 5 * (1 << 20) + 7):
        st, h, b = one(port, b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
        t.check(st == b"HTTP/1.1 200 OK" and b == pattern(n), f"RT-12a GET /{n}: 200, Content-Length {n}, every byte i % 251")
    st, h, b = one(port, b"HEAD /5000 HTTP/1.1\r\nHost: x\r\n\r\n", expect_body=False)
    t.check(st == b"HTTP/1.1 200 OK" and h[b"content-length"] == b"5000" and b == b"", "RT-12a HEAD /5000 has the headers of the GET and no body")
    st, h, b = one(port, b"GET /nothing-here HTTP/1.1\r\n\r\n")
    t.check(st.startswith(b"HTTP/1.1 404") and b == b"", "RT-12a an unknown path is a 404")
    st, h, b = one(port, b"DELETE / HTTP/1.1\r\n\r\n")
    t.check(st.startswith(b"HTTP/1.1 405"), "RT-12a a method other than GET and HEAD is a 405")
    c = connect(port, timeout=10)
    c.sendall(b"this is not http\r\n\r\n")
    st, h, b = read_response(c)
    t.check(st.startswith(b"HTTP/1.1 400") and closed_after(c), "RT-12a garbage is a 400 and the connection is closed")
    c = connect(port, timeout=10)
    c.sendall(b"GET / HTTP/1.1\r\nX: " + b"a" * 6000)
    try:
        st, h, b = read_response(c)
        ok = st.startswith(b"HTTP/1.1 431") and closed_after(c)
    except (EOFError, ConnectionResetError):
        ok = True                                                    # dropping it is also acceptable; the worker must survive
    t.check(ok, "RT-12a a head over 4 KiB is refused (431) and the connection closed")
    t.check(one(port, b"GET /100 HTTP/1.1\r\n\r\n")[2] == pattern(100), "RT-12a ... and the server still answers")

def rt12b(port):
    c = connect(port, timeout=20)
    for n in (10, 20000, 3, 40000, 0, 1):
        c.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
        st, h, b = read_response(c)
        if b != pattern(n):
            break
    t.check(b == pattern(1), "RT-12b six requests on one keep-alive connection, bodies of 10 B to 40 kB, all correct")
    c.sendall(b"GET /10 HTTP/1.1\r\n\r\nGET /20000 HTTP/1.1\r\n\r\nGET /7 HTTP/1.1\r\nConnection: close\r\n\r\n")
    got = [read_response(c) for _ in range(3)]
    t.check([len(x[2]) for x in got] == [10, 20000, 7] and all(x[2] == pattern(len(x[2])) for x in got), "RT-12b three pipelined requests in one write are answered in order")
    t.check(got[2][1].get(b"connection") == b"close" and closed_after(c), "RT-12b 'Connection: close' is answered, then the server closes")
    head = b"GET /77 HTTP/1.1\r\nHost: example\r\nUser-Agent: http_server_test\r\n\r\n"
    bad = 0
    for cut in range(1, len(head)):
        c = connect(port, timeout=10)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        c.sendall(head[:cut]); time.sleep(0.001); c.sendall(head[cut:])
        try:
            if read_response(c)[2] != pattern(77):
                bad += 1
        except (EOFError, OSError):
            bad += 1
        c.close()
    t.check(bad == 0, f"RT-12b a request head cut at each of its {len(head) - 1} positions is answered once, correctly ({bad} bad)")
    c = connect(port, timeout=10)
    c.sendall(b"POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345")
    time.sleep(0.05)
    c.sendall(b"67890GET /9 HTTP/1.1\r\n\r\n")
    got = [read_response(c) for _ in range(2)]
    t.check(got[0][0].startswith(b"HTTP/1.1 405") or got[0][0].startswith(b"HTTP/1.1 404"), "RT-12b a POST with a body is answered")
    t.check(got[1][2] == pattern(9), "RT-12b ... its body is skipped (it arrived in two pieces) and the next request on the connection is answered")
    c = connect(port, timeout=10)
    c.sendall(b"GET /5 HTTP/1.0\r\n\r\n")
    st, h, b = read_response(c)
    t.check(b == pattern(5) and closed_after(c), "RT-12b HTTP/1.0 without keep-alive is answered and closed")
    c = connect(port, timeout=10)
    c.sendall(b"GET /5 HTTP/1.1\r\nCONNECTION: Close\r\n\r\n")
    st, h, b = read_response(c)
    t.check(b == pattern(5) and closed_after(c), "RT-12b header names and values are matched without regard to case")

def rt12c(port, rss):
    # A client that reads slowly while the server sends 64 MiB: backpressure, no loss, no growth.
    n = 64 * (1 << 20)
    c = connect(port, timeout=60)
    c.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
    c.sendall(b"GET /%d HTTP/1.1\r\nConnection: close\r\n\r\n" % n)
    buf = _LEFT.pop(c.fileno(), b"")          # bytes of a pipelined next response read earlier
    while b"\r\n\r\n" not in buf:
        buf += c.recv(65536)
    head, rest = buf.split(b"\r\n\r\n", 1)
    got = len(rest); ok = rest == pattern(len(rest)); peak = rss()
    t0 = time.time()
    while got < n:
        d = c.recv(65536)
        if not d:
            break
        if d != pattern(len(d), got):
            ok = False
        got += len(d)
        if got < (1 << 20) * 8:
            time.sleep(0.0005)                                      # slow at first, so the server's queue fills
        peak = max(peak, rss()) if got % (8 << 20) < 65536 else peak
    t.check(got == n and ok, f"RT-12c 64 MiB to a slow reader arrives complete and byte-exact ({got} of {n} bytes, {time.time() - t0:.1f}s)")
    t.check(rss() - peak < 4096 and peak - base_rss < 40 * 1024, f"RT-12c ... without the server growing: RSS {base_rss} kB before, {peak} kB at the most")

def rt12d(port, root):
    expected = {}
    for dirpath, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            expected["/" + os.path.relpath(p, root).replace(os.sep, "/")] = open(p, "rb").read()
    ok = True; types = {}
    for path, data in expected.items():
        st, h, b = one(port, b"GET " + path.encode() + b" HTTP/1.1\r\n\r\n")
        types[path] = h.get(b"content-type")
        if st != b"HTTP/1.1 200 OK" or b != data:
            ok = False
    t.check(ok and len(expected) >= 4, f"RT-12d every one of the {len(expected)} files under --root is served byte-exact, nested ones included")
    t.check(types.get("/index.html", b"").startswith(b"text/html") and types.get("/css/site.css") == b"text/css"
            and types.get("/blob.bin") == b"application/octet-stream", f"RT-12d content types by extension ({types})")
    st, h, b = one(port, b"GET /css HTTP/1.1\r\n\r\n")
    t.check(st.startswith(b"HTTP/1.1 404"), "RT-12d a directory is not a file: 404")

def rt12e(port):
    clients, per = 200, 500
    errors = []
    def client(i):
        c = connect(port, timeout=60)
        for k in range(per):
            n = (i * 7 + k * 13) % 3000
            c.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
            st, h, b = read_response(c)
            if b != pattern(n):
                errors.append((i, k)); return
        c.close()
    t0 = time.time()
    res = run_threads([lambda i=i: client(i) for i in range(clients)])
    failed = [r for r in res if isinstance(r, Exception)]
    took = time.time() - t0
    t.note(f"RT-12e measured: {clients * per} requests, {clients} keep-alive clients, {took:.1f}s = {clients * per / took:.0f} req/s (python client; the server is not the limit)")
    t.check(not failed and not errors, f"RT-12e {clients * per} requests from {clients} keep-alive clients, every body byte-exact ({len(failed)} client failures, {len(errors)} wrong; {failed[:1]})")

base_rss = 0
def body():
    global base_rss
    out = tempfile.mkdtemp(prefix="tcprouter_http_")
    try:
        exe = os.path.join(out, "http_server")
        r = subprocess.run([GOOSE, "build", "--debug", "-o", exe, os.path.join(ROOT, "examples", "http_server.goose")], capture_output=True, text=True)
        t.check(r.returncode == 0 and os.path.exists(exe), f"RT-12a examples/http_server.goose builds ({(r.stdout + r.stderr).strip()[-300:] if r.returncode else 'ok'})")
        root = os.path.join(out, "site")
        os.makedirs(os.path.join(root, "css")); os.makedirs(os.path.join(root, "a", "b"))
        files = {"index.html": b"<html>" + b"x" * 5000 + b"</html>", "css/site.css": b"body{margin:0}" * 100, "blob.bin": os.urandom(300000),
                 "a/b/deep.txt": b"deep\n" * 1000, "empty.txt": b""}
        for name, data in files.items():
            open(os.path.join(root, name), "wb").write(data)
        port = free_port()
        proc = subprocess.Popen([exe, "--port", str(port), "--workers", "2", "--root", root], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def rss():
            return int([l for l in open(f"/proc/{proc.pid}/status") if l.startswith("VmRSS")][0].split()[1])
        try:
            for _ in range(200):
                if not port_is_free(port):
                    break
                time.sleep(0.05)
            t.check(proc.poll() is None, "RT-12a the server is running")
            rt12a(port)
            rt12b(port)
            base_rss = rss()
            rt12c(port, rss)
            rt12d(port, root)
            rt12e(port)
            t.check(proc.poll() is None, "RT-12e the server is still running after all of it")
        finally:
            proc.terminate()
            try: proc.wait(10)
            except subprocess.TimeoutExpired: proc.kill()
            err = proc.stderr.read()
            t.check(not err.strip(), f"RT-12a the server wrote nothing to stderr ({err.strip()[:200]!r})")
    finally:
        shutil.rmtree(out, ignore_errors=True)

t.run(body)
t.finish()
