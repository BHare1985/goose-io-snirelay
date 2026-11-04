#!/usr/bin/env python3
"""Correctness harness for the edge path (TLS passthrough). Usage: verify_sni.py PORT [PROXY_PID]
Expects the backends proxybench.sh sets up for SUITE=edge: a.localhost -> service "a" (one server),
b.localhost -> service "b" (replicas b1, b2), each with the peer as backup; unknown or missing SNI is
closed. Servers answer GET /who (the service), GET /inst (the instance) and GET /<N> files whose
body[i] = i % 251. With EDGE_WORK set, failover checks flip the servers' health through
$EDGE_WORK/unhealthy_<inst>; EDGE_PASSIVE=1 (nginx OSS: no active checks) skips them."""
import os, random, socket, ssl, sys, threading, time
EDGE_WORK = os.environ.get("EDGE_WORK")
PASSIVE = os.environ.get("EDGE_PASSIVE") == "1"

PORT = int(sys.argv[1])
PID = int(sys.argv[2]) if len(sys.argv) > 2 else None
TMO = 15
SIZES = (0, 1, 11, 4096, 16384, 65535, 65536, 65537, 300000, 1 << 20, 16 << 20)   # files the bench creates

PAT = bytes(range(251))
def pattern(n):
    return (PAT * (n // 251 + 1))[:n]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

def raw():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=TMO)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s

def tls(host="a.localhost"):
    return CTX.wrap_socket(raw(), server_hostname=host)

def read_response(s, rest=b""):
    """Read one response from a socket-like object with recv(); returns (body, leftover)."""
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
    while len(rest) < cl:
        d = s.recv(1 << 20)
        if not d:
            raise EOFError("eof with %d/%d" % (len(rest), cl))
        rest += d
    return bytes(rest[:cl]), bytes(rest[cl:])

def get(s, path, left=b""):
    s.sendall(b"GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path)
    return read_response(s, left)

def who(host):
    s = tls(host)
    body, _ = get(s, b"/who")
    s.close()
    return body.strip().decode()

class BioConn:
    """TLS over a raw socket through memory BIOs, so a test controls exactly how the ClientHello
    reaches the wire: shape(hello) returns the list of byte chunks to send, with a pause between."""
    def __init__(self, host, shape, pause=0.15):
        self.s = raw()
        self.inb, self.outb = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.o = CTX.wrap_bio(self.inb, self.outb, server_hostname=host)
        try:
            self.o.do_handshake()
        except ssl.SSLWantReadError:
            pass
        for i, chunk in enumerate(shape(self.outb.read())):
            if i:
                time.sleep(pause)
            self.s.sendall(chunk)
        while True:
            try:
                self.o.do_handshake(); self._flush(); break
            except ssl.SSLWantReadError:
                self._flush(); self._fill()
    def _flush(self):
        d = self.outb.read()
        if d:
            self.s.sendall(d)
    def _fill(self):
        d = self.s.recv(65536)
        if not d:
            raise EOFError("eof during TLS")
        self.inb.write(d)
    def sendall(self, b):
        self.o.write(b); self._flush()
    def recv(self, n):
        while True:
            try:
                return self.o.read(n)
            except ssl.SSLWantReadError:
                self._fill()
            except ssl.SSLZeroReturnError:
                return b""
    def close(self):
        self.s.close()

def bio_who(host, shape):
    c = BioConn(host, shape)
    body, _ = get(c, b"/who")
    c.close()
    return body.strip().decode()

def refragment(hello, k):
    """Split one handshake record into two TLS records (legal, rarely seen in practice)."""
    assert hello[0] == 22
    body = hello[5:5 + int.from_bytes(hello[3:5], "big")]
    rec = lambda b: hello[:3] + len(b).to_bytes(2, "big") + b
    return rec(body[:k]) + rec(body[k:]) + hello[5 + len(body):]

results = []
def check(name, fn):
    t = time.time()
    try:
        fn()
        results.append((name, True, "%.2fs" % (time.time() - t)))
    except Exception as e:
        results.append((name, False, "%s: %s" % (type(e).__name__, str(e)[:100])))
    print("%-38s %s  %s" % (name, "PASS" if results[-1][1] else "FAIL", results[-1][2]), flush=True)

def rejected(host):
    """True if the proxy closes a client asking for `host` (None = no SNI) before any backend answers."""
    try:
        s = CTX.wrap_socket(raw(), server_hostname=host)
    except (ssl.SSLError, OSError):
        return True
    try:
        get(s, b"/who")
        return False
    except (ssl.SSLError, OSError, EOFError):
        return True
    finally:
        s.close()

def inst(host="b.localhost"):
    s = tls(host)
    body, _ = get(s, b"/inst")
    s.close()
    return body.strip().decode()

def t_routing():
    for host, want in (("a.localhost", "a"), ("b.localhost", "b")):
        got = who(host)
        assert got == want, "%s went to %r, want %r" % (host, got, want)
    assert rejected("unknown.localhost"), "unknown name was not closed"

def t_case():
    got = who("B.LocalHost")
    assert got == "b", "B.LocalHost went to %r, want 'b' (names are case-insensitive)" % got

def t_no_sni():
    assert rejected(None), "client without SNI was not closed"

def t_replicas():
    seen = [inst() for _ in range(20)]
    assert set(seen) == {"b1", "b2"}, "b's replicas not both used: %r" % seen

def flag(name, on):
    path = os.path.join(EDGE_WORK, "unhealthy_" + name)
    if on:
        open(path, "w").close()
    elif os.path.exists(path):
        os.remove(path)

def settles(want, secs=6.0):
    """Wait until 8 new connections in a row are served by exactly the instances in `want`."""
    end = time.time() + secs
    while time.time() < end:
        got = {inst() for _ in range(8)}
        if got == want:
            return got
        time.sleep(0.2)
    raise AssertionError("still served by %r after %.0fs, want only %r" % (got, secs, want))

def t_failover():
    try:
        flag("b2", True)                      # one replica unhealthy: the other takes everything
        settles({"b1"})
        flag("b2", False)
        settles({"b1", "b2"})                 # b2 back after --rise checks
        flag("b1", True); flag("b2", True)    # every local replica unhealthy: the peer (backup)
        settles({"peer"})
        flag("b1", False); flag("b2", False)  # local again: the backup is left
        settles({"b1", "b2"})
    finally:
        for n in ("b1", "b2"):
            flag(n, False)

def t_split_segments():
    # ClientHello arrives in 3 TCP writes: inside the record header, mid-body, rest
    for host, want in (("b.localhost", "b"), ("a.localhost", "a")):
        got = bio_who(host, lambda h: [h[:3], h[3:200], h[200:]])
        assert got == want, "split hello for %s went to %r" % (host, got)

def t_split_records():
    # ClientHello fragmented across two TLS records, sent together and then separately
    got = bio_who("b.localhost", lambda h: [refragment(h, 40)])
    assert got == "b", "2-record hello went to %r" % got
    got = bio_who("b.localhost", lambda h: [refragment(h, 40)[:50], refragment(h, 40)[50:]])
    assert got == "b", "2-record hello (2 writes) went to %r" % got

def t_sizes():
    for host in ("a.localhost", "b.localhost"):
        s = tls(host); left = b""
        for n in SIZES:
            body, left = get(s, b"/%d" % n, left)
            assert body == pattern(n), "%s: content mismatch for size %d (got %d bytes)" % (host, n, len(body))
        s.close()

def t_pipelined():
    s = tls("b.localhost")
    sizes = [11, 65537, 1, 300000, 0]
    s.sendall(b"".join(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % n for n in sizes))
    left = b""
    for n in sizes:
        body, left = read_response(s, left)
        assert body == pattern(n), "pipelined mismatch size %d" % n
    s.close()

def t_concurrent():
    errs = []
    def w(seed):
        r = random.Random(seed)
        try:
            host = r.choice(["a.localhost", "b.localhost"])
            s = tls(host); left = b""
            for _ in range(10):
                n = r.choice([1, 11, 4096, 65536, 300000, 1 << 20])
                body, left = get(s, b"/%d" % n, left)
                if body != pattern(n):
                    errs.append("mismatch size %d" % n); return
            body, left = get(s, b"/who", left)
            if body.strip().decode() != host[0]:
                errs.append("%s answered by %r" % (host, body)); return
            s.close()
        except Exception as e:
            errs.append(repr(e))
    th = [threading.Thread(target=w, args=(i,)) for i in range(32)]
    [t.start() for t in th]; [t.join() for t in th]
    assert not errs, errs[:2]

def served_promptly(what):
    t = time.time()
    got = who("b.localhost")
    dt = time.time() - t
    assert got == "b" and dt < 2.0, "a normal client took %.1fs / got %r while %s" % (dt, got, what)

def t_not_tls():
    s = raw()
    s.sendall(b"GET /11 HTTP/1.1\r\nHost: x\r\n\r\n")
    served_promptly("a plain-HTTP client was connected")
    s.close()

def t_stalled():
    # silent clients, clients stuck inside the record header, and inside a record
    idle = [raw() for _ in range(50)]
    hdr = [raw() for _ in range(20)]
    for s in hdr:
        s.sendall(b"\x16\x03\x01")
    part = [raw() for _ in range(20)]
    for s in part:
        s.sendall(b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03")
    time.sleep(0.3)
    served_promptly("90 clients were stalled before routing")
    for s in idle + hdr + part:
        s.close()

def fdcount():
    return len(os.listdir("/proc/%d/fd" % PID))

def t_churn():
    before = fdcount() if PID else 0
    for i in range(600):
        host = ("a.localhost", "b.localhost")[i % 2]
        if i % 4 == 3:                                   # gone before the ClientHello completes
            s = raw(); s.sendall(b"\x16\x03\x01\x02"); s.close(); continue
        s = tls(host)
        body, _ = get(s, b"/11")
        assert len(body) == 11
        if i % 4 == 1:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")  # RST
        s.close()
    for i in range(50):                                  # abandon mid-transfer
        s = tls("b.localhost")
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n" % (16 << 20))
        s.recv(1000)
        s.close()
    if PID:
        for _ in range(50):
            time.sleep(0.2)
            after = fdcount()
            if after <= before + 4:
                break
        assert after <= before + 4, "fd leak: %d -> %d" % (before, after)

check("routing a / b, unknown name closed", t_routing)
check("SNI is case-insensitive", t_case)
check("no SNI -> closed", t_no_sni)
check("b's two replicas both used", t_replicas)
check("ClientHello split over 3 TCP writes", t_split_segments)
check("ClientHello split over 2 TLS records", t_split_records)
check("sizes 0..16MiB keepalive, both backends", t_sizes)
check("pipelined requests (ordering)", t_pipelined)
check("32 concurrent mixed clients, both names", t_concurrent)
check("non-TLS client does not block others", t_not_tls)
check("90 stalled pre-routing clients", t_stalled)
check("churn / early aborts / fd leak", t_churn)
if EDGE_WORK and not PASSIVE:
    check("failover: unhealthy replica, all local -> peer", t_failover)
elif EDGE_WORK:
    print("%-38s SKIP  no active health checks (nginx OSS)" % "failover via health checks", flush=True)
ok = all(r[1] for r in results)
print("RESULT:", "ALL PASS" if ok else "FAILURES")
sys.exit(0 if ok else 1)
