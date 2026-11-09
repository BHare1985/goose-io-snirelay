#!/usr/bin/env python3
"""examples/http_server (Goose, tcprouter handler mode) against bench/backend (C, epoll), same host, same wrk lines, same rows as
RESULTS.md: 11 B keep-alive c=64, 11 B new connection per request c=64, 16 KiB c=64, 64 KiB c=64, 1 MiB c=16. One worker/thread each.

    bench/run_http_server.sh        (takes the host lock; do not run while the Gatekeeper testbed is up)

Prints a markdown table (median of ROUNDS runs of SECS seconds) and verifies a /N response byte for byte before measuring."""
import os, re, signal, socket, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tests", "net", "harness"))
from netlib import free_port
SECS = int(os.environ.get("SECS", "8")); ROUNDS = int(os.environ.get("ROUNDS", "3"))
ROWS = [("11 B keep-alive", 11, 64, False), ("11 B new connection", 11, 64, True), ("16 KiB", 16384, 64, False),
        ("64 KiB", 65536, 64, False), ("1 MiB", 1048576, 16, False)]

def start(name):
    port = free_port()
    if name == "c_backend":
        argv = [os.path.join(HERE, "backend"), "1", str(port)]
    else:
        argv = [os.path.join(HERE, "http_server"), "--port", str(port), "--workers", "1"]
    p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close(); break
        except OSError:
            time.sleep(0.05)
    return p, port

def verify(port):
    for n in (11, 16384, 1048576):
        c = socket.create_connection(("127.0.0.1", port)); c.sendall(b"GET /%d HTTP/1.1\r\nConnection: close\r\n\r\n" % n)
        buf = b""
        while True:
            d = c.recv(1 << 20)
            if not d: break
            buf += d
        body = buf.split(b"\r\n\r\n", 1)[1]
        if body != bytes(i % 251 for i in range(n)): raise SystemExit(f"wrong body for /{n}")

def wrk(port, size, conns, close):
    cmd = ["wrk", "-t1", f"-c{conns}", f"-d{SECS}s"] + (["-H", "Connection: close"] if close else []) + [f"http://127.0.0.1:{port}/{size}"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    m = re.search(r"Requests/sec:\s+([\d.]+)", out)
    bad = re.search(r"Non-2xx|Socket errors", out)
    if not m or bad: raise SystemExit("wrk problem:\n" + out)
    return float(m.group(1))

subprocess.run(["cc", "-O2", "-o", os.path.join(HERE, "backend"), os.path.join(HERE, "backend.c"), "-lpthread"], check=True) if not os.path.exists(os.path.join(HERE, "backend")) else None
res = {}
for name in ("c_backend", "goose"):
    p, port = start(name)
    try:
        verify(port)
        for label, size, conns, close in ROWS:
            wrk(port, size, conns, close)                                       # warm-up
            res[(name, label)] = statistics.median(wrk(port, size, conns, close) for _ in range(ROUNDS))
    finally:
        p.send_signal(signal.SIGTERM); p.wait(10)
print("| row | C backend (req/s) | Goose http_server (req/s) | ratio |\n|---|---|---|---|")
for label, *_ in ROWS:
    c, g = res[("c_backend", label)], res[("goose", label)]
    print(f"| {label} | {c:,.0f} | {g:,.0f} | {100 * g / c:.1f}% |")
