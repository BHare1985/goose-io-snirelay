#!/usr/bin/env python3
"""Correctness harness for the proxy. Usage: verify.py PORT [PROXY_PID]
Backend body pattern: body[i] = i % 251."""
import os, random, socket, sys, threading, time

PORT = int(sys.argv[1])
PID = int(sys.argv[2]) if len(sys.argv) > 2 else None
TMO = 15
HELLO = bytes.fromhex(os.environ.get("VERIFY_HELLO", ""))   # proxybench sni-plain: a ClientHello first

def opened(s):
    if HELLO:
        s.sendall(HELLO)
    return s

PAT = bytes(range(251))
def pattern(n):
    return (PAT * (n // 251 + 1))[:n]

def conn():
    s = opened(socket.create_connection(("127.0.0.1", PORT), timeout=TMO))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s

def read_exact(s, buf, n):
    while len(buf) < n:
        d = s.recv(1 << 20)
        if not d:
            raise EOFError("eof with %d/%d" % (len(buf), n))
        buf += d
    return buf

def read_response(s, rest=b""):
    """Read one response; returns (body, leftover)."""
    buf = bytearray(rest)
    while b"\r\n\r\n" not in buf:
        d = s.recv(65536)
        if not d:
            raise EOFError("eof in headers")
        buf += d
    i = buf.index(b"\r\n\r\n") + 4
    hdr = bytes(buf[:i]).decode()
    assert hdr.startswith("HTTP/1.1 200"), hdr[:40]
    cl = int([l for l in hdr.split("\r\n") if l.lower().startswith("content-length")][0].split(":")[1])
    rest = bytearray(buf[i:])
    read_exact(s, rest, cl)
    return bytes(rest[:cl]), bytes(rest[cl:])

results = []
def check(name, fn):
    t = time.time()
    try:
        fn()
        results.append((name, True, "%.2fs" % (time.time() - t)))
    except Exception as e:
        results.append((name, False, "%s: %s" % (type(e).__name__, str(e)[:100])))
    print("%-34s %s  %s" % (name, "PASS" if results[-1][1] else "FAIL", results[-1][2]), flush=True)

def t_sizes():
    s = conn()
    left = b""
    for n in (0, 1, 11, 1000, 4096, 65535, 65536, 65537, 300000, 1 << 20, 16 << 20):
        for _ in range(2):
            s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
            body, left = read_response(s, left)
            assert len(body) == n, "len %d != %d" % (len(body), n)
            assert body == pattern(n), "content mismatch for size %d" % n
    s.close()

def t_pipelined():
    s = conn()
    sizes = [100, 70000, 5, 200000, 11]
    s.sendall(b"".join(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n for n in sizes))
    left = b""
    for n in sizes:
        body, left = read_response(s, left)
        assert body == pattern(n), "pipelined mismatch size %d" % n
    s.close()

def t_halfclose():
    # client sends request then FIN; response must still arrive in full
    for n in (11, 1 << 20):
        s = conn()
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
        s.shutdown(socket.SHUT_WR)
        body, _ = read_response(s)
        assert body == pattern(n), "half-close lost data (size %d)" % n
        s.close()

def t_concurrent():
    errs = []
    def w(seed):
        r = random.Random(seed)
        try:
            s = conn(); left = b""
            for _ in range(15):
                n = r.choice([1, 100, 5000, 65536, 100000, 700000, 2 << 20])
                s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n)
                body, left = read_response(s, left)
                if body != pattern(n):
                    errs.append("mismatch size %d" % n); return
            s.close()
        except Exception as e:
            errs.append(repr(e))
    th = [threading.Thread(target=w, args=(i,)) for i in range(48)]
    [t.start() for t in th]; [t.join() for t in th]
    assert not errs, errs[:2]

def read_to_eof(s):
    buf = bytearray()
    while True:
        d = s.recv(1 << 20)
        if not d:
            return bytes(buf)
        buf += d

def t_server_close():
    """Backend closes right after its response (Connection: close): body intact, then EOF. Also a slow
    client behind a pipelined 2 MB response, so the closing response finds the client side full."""
    for n in (0, 11, 1000, 20000, 32767, 32768, 100000):
        s = conn()
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % n)
        body, left = read_response(s)
        rest = read_to_eof(s)
        assert body == pattern(n) and not left and not rest, "server-close size %d: bad body or extra bytes" % n
        s.close()
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    s.settimeout(TMO)
    s.connect(("127.0.0.1", PORT)); opened(s)
    s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\nGET /11 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % (2 << 20))
    time.sleep(0.5)
    b1, left = read_response(s)
    b2, left = read_response(s, left)
    rest = read_to_eof(s)
    assert b1 == pattern(2 << 20) and b2 == pattern(11) and not left and not rest, "slow client + server close: bad data"
    s.close()

def fdcount():
    return len(os.listdir("/proc/%d/fd" % PID))

def t_churn():
    before = fdcount() if PID else 0
    for i in range(3000):
        s = conn()
        s.sendall(b"GET /11 HTTP/1.1\r\nHost: x\r\n\r\n")
        body, _ = read_response(s)
        assert len(body) == 11
        if i % 3 == 0:
            s.close()
        elif i % 3 == 1:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")  # RST
            s.close()
        else:
            s.shutdown(socket.SHUT_WR); s.close()
    # abandon mid-transfer connections too
    for i in range(200):
        s = conn()
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % (8 << 20))
        s.recv(1000)
        s.close()
    if PID:
        for _ in range(50):
            time.sleep(0.2)
            after = fdcount()
            if after <= before + 4:
                break
        assert after <= before + 4, "fd leak: %d -> %d" % (before, after)

def t_slow_readers():
    """Many clients request a big body and then stop reading. A well-behaved client must still be
    served promptly (no starvation of shared buffers), and the stalled ones must later receive
    their complete, uncorrupted body."""
    slow = []
    for _ in range(150):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        s.settimeout(TMO)
        s.connect(("127.0.0.1", PORT)); opened(s)
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % (6 << 20))
        slow.append(s)
    time.sleep(1.0)                     # let every slow client's transfer stall
    t = time.time()
    f = conn(); f.settimeout(4)
    left = b""
    for _ in range(20):
        f.sendall(b"GET /100000 HTTP/1.1\r\nHost: x\r\n\r\n")
        body, left = read_response(f, left)
        assert body == pattern(100000), "fast client got corrupted data"
    dt = time.time() - t
    f.close()
    assert dt < 3.0, "fast client starved: %.1fs for 20 small requests" % dt
    for s in slow[:12]:                 # now drain a sample of the stalled ones, verify content
        body, _ = read_response(s)
        assert body == pattern(6 << 20), "slow reader got corrupted data"
    for s in slow:
        s.close()

check("sizes 0..16MiB keepalive", t_sizes)
check("pipelined requests (ordering)", t_pipelined)
check("half-close (client FIN after req)", t_halfclose)
check("server closes after response", t_server_close)
check("48 concurrent mixed-size clients", t_concurrent)
check("connection churn / aborts / fd leak", t_churn)
check("150 stalled readers vs fast client", t_slow_readers)
ok = all(r[1] for r in results)
print("RESULT:", "ALL PASS" if ok else "FAILURES")
sys.exit(0 if ok else 1)
