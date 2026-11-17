#!/usr/bin/env python3
"""Gate proof for early-close-retry (task 1.1).

Question: can a proxy keep the client's ClientHello in the client socket, send a copy of it to server A,
and, when A ends without a byte, send the very same bytes to server B, so that B completes the handshake?

The proxy side is plain sockets: MSG_PEEK on the client socket (the hello is never consumed), send to A,
read A until it ends, then send the same peeked bytes to B. Only when B's first byte arrives is the hello
consumed from the client socket (recv without MSG_PEEK). Server A accepts and closes (or resets) without
sending a byte. Server B is a real TLS server. The client is a real TLS client that sees one handshake.

Prints PASS/FAIL lines; exit status is non-zero on a failure. Needs python3 and the openssl CLI.
"""
import os, socket, ssl, subprocess, sys, tempfile, threading, struct

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail else ""))
    if not ok: fails += 1

tmp = tempfile.mkdtemp()
cert, key = tmp + "/c.pem", tmp + "/k.pem"
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
                "-subj", "/CN=gate.test", "-addext", "subjectAltName=DNS:gate.test"], check=True, capture_output=True)

def listener():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0)); s.listen(8); return s

def server_a(ls, mode):
    """Accepts, reads the hello (so the close is after the request, like a stopping server), then ends without a byte."""
    c, _ = ls.accept(); c.recv(65536)
    if mode == "rst":
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    c.close()

def server_b(ls):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
    c, _ = ls.accept()
    with ctx.wrap_socket(c, server_side=True) as t:
        t.recv(1); t.sendall(b"served-by-B")

def run(mode):
    la, lb, lp = listener(), listener(), listener()
    threading.Thread(target=server_a, args=(la, mode), daemon=True).start()
    threading.Thread(target=server_b, args=(lb,), daemon=True).start()
    result = {}
    def client():
        ctx = ssl.create_default_context(cafile=cert)
        try:
            with socket.create_connection(lp.getsockname()) as raw, ctx.wrap_socket(raw, server_hostname="gate.test") as t:
                t.sendall(b"x"); result["body"] = t.recv(64)
        except Exception as e:
            result["err"] = repr(e)
    ct = threading.Thread(target=client); ct.start()

    cli, _ = lp.accept()
    # the "proxy": peek, never consume
    import time
    hello = b""
    for _ in range(100):
        hello = cli.recv(65536, socket.MSG_PEEK)
        if hello: break
        time.sleep(0.01)
    check(f"{mode}: hello peeked", len(hello) > 100 and hello[0] == 0x16, f"{len(hello)} bytes")
    # attempt 1: server A
    a = socket.create_connection(la.getsockname()); a.sendall(hello)
    a.settimeout(2); end = a.recv(1) if mode == "close" else None
    if mode == "rst":
        try: end = a.recv(1)
        except ConnectionResetError: end = b""
    check(f"{mode}: A ended with no byte", end == b"")
    a.close()
    still = cli.recv(65536, socket.MSG_PEEK)
    check(f"{mode}: hello still in the client socket", still == hello)
    # attempt 2: server B gets the same bytes
    b = socket.create_connection(lb.getsockname()); b.sendall(hello)
    first = b.recv(1, socket.MSG_WAITALL)
    check(f"{mode}: B answered", len(first) == 1 and first[0] == 0x16)
    # first server byte: now consume the hello from the client, then relay both ways
    got = cli.recv(len(hello))
    check(f"{mode}: hello consumed after B's first byte", got == hello)
    cli.sendall(first)
    def up():
        try:
            while d := cli.recv(65536): b.sendall(d)
        except OSError: pass
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass
    threading.Thread(target=up, daemon=True).start()
    b.settimeout(5)
    try:
        while d := b.recv(65536): cli.sendall(d)
    except OSError: pass
    cli.close(); ct.join(10)
    check(f"{mode}: client finished the TLS handshake and got B's answer", result.get("body") == b"served-by-B", str(result))

for m in ("close", "rst"): run(m)
print("FAILED" if fails else "ALL PASS", fails)
sys.exit(1 if fails else 0)
