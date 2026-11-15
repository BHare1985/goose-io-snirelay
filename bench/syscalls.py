#!/usr/bin/env python3
"""Syscalls per request for the two proxies, the same way: strace -c -f on the proxy during a short wrk run against backend.c.
  python3 bench/syscalls.py   (host must be free; strace slows both proxies, which makes counts comparable but not throughput)
"""
import os, re, signal, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tests", "net", "harness"))
from netlib import free_port
CP = os.path.expanduser("~/dev/cnamecloud/c_proxy/proxy"); GO = os.path.join(HERE, "forward_server"); BE = os.path.join(HERE, "backend")

def run(name, argv, bport, size, tag, close=False):
    port = free_port()
    out = f"/tmp/strace-{name}-{size}{'-close' if close else ''}.txt"
    p = subprocess.Popen(["strace", "-c", "-f", "-o", out] + argv(port, bport), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    w = subprocess.run(["wrk", "-t1", "-c16", "-d4s"] + (["-H", "Connection: close"] if close else []) + [f"http://127.0.0.1:{port}/{size}"], capture_output=True, text=True).stdout
    reqs = int(re.search(r"(\d+) requests in", w).group(1))
    for q in subprocess.run(["pgrep", "-f", argv(port, bport)[0]], capture_output=True, text=True).stdout.split():
        try: os.kill(int(q), signal.SIGINT)
        except OSError: pass
    p.wait(timeout=20)
    rows = []; total = 0
    for line in open(out):
        m = re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(\d+)?\s*(\w+)$", line) or re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+()(\w+)$", line)
        if m: rows.append((m.group(3), int(m.group(1))))
        if line.strip().endswith("total"): total = int(line.split()[3] if line.split()[3].isdigit() else line.split()[-2])
    rows.sort(key=lambda r: -r[1])
    print(f"{name:12} {size:>8} B{' new-conn' if close else ''}  requests={reqs}  total syscalls={total}  per request={total/reqs:.1f}  top: " + ", ".join(f"{n}={c/reqs:.2f}" for n, c in rows[:8]), flush=True)

bport = free_port()
be = subprocess.Popen([BE, "1", str(bport)], stdout=subprocess.DEVNULL); time.sleep(0.5)
try:
    for size, close in ((16384, False), (1048576, False), (11, True)):
        run("c_epoll_copy", lambda l, b: [CP, "-l", str(l), "-b", str(b), "-t", "1", "--io", "epoll", "-m", "copy"], bport, size, "c", close)
        run("goose", lambda l, b: [GO, "--listen", f"127.0.0.1:{l}", "--to", f"127.0.0.1:{b}", "--workers", "1", "--stat-ms", "3600000"], bport, size, "g", close)
finally:
    be.terminate()
