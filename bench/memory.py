#!/usr/bin/env python3
"""Resident memory of the two proxies, measured the same way for both (the bench itself does not report RSS).

  python3 bench/memory.py            idle, with 1,000 and 10,000 idle connections held open, and under a short wrk load

For each of: C proxy (--io epoll -m copy), C proxy (--io epoll -m hybrid), Goose forward_server. Reads VmRSS and VmHWM from
/proc/PID/status. Per-idle-connection memory is (RSS with N idle - RSS idle) / N. Run it ONLY when the host is free (see run_m6.sh).
Raw numbers go to bench/results/memory-<timestamp>.json.
"""
import json, os, socket, subprocess, sys, time, resource
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tests", "net", "harness"))
from netlib import free_port, rss_kb

CPROXY = os.path.expanduser("~/dev/cnamecloud/c_proxy/proxy")
GOOSE = os.path.join(HERE, "forward_server")
BACKEND = os.path.join(HERE, "backend")

def hwm_kb(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmHWM:"):
            return int(line.split()[1])
    return 0

def start(argv):
    p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    return p

def wait_port(port):
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"port {port} never opened")

def hold(port, n):
    conns = []
    for _ in range(n):
        conns.append(socket.create_connection(("127.0.0.1", port), timeout=10))
    time.sleep(1.0)
    return conns

def measure(name, argv_for, bport, results):
    port = free_port()
    p = start(argv_for(port, bport))
    try:
        wait_port(port)
        r = {"idle_rss_kb": rss_kb(p.pid)}
        for n in (1000, 10000):
            conns = hold(port, n)
            r[f"rss_kb_with_{n}_idle"] = rss_kb(p.pid)
            r[f"bytes_per_idle_connection_{n}"] = round((r[f"rss_kb_with_{n}_idle"] - r["idle_rss_kb"]) * 1024 / n)
            for c in conns:
                c.close()
            time.sleep(1.0)
        # under load: wrk, 64 connections, 5 s, 16 KiB responses; sample the process while it runs
        wrk = subprocess.Popen(["wrk", "-t2", "-c64", "-d5s", f"http://127.0.0.1:{port}/16384"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        peak = 0
        while wrk.poll() is None:
            peak = max(peak, rss_kb(p.pid)); time.sleep(0.2)
        r["rss_kb_under_load_peak"] = peak
        r["vmhwm_kb"] = hwm_kb(p.pid)
        results[name] = r
        print(name, r, flush=True)
    finally:
        p.terminate(); p.wait()

def main():
    resource.setrlimit(resource.RLIMIT_NOFILE, (resource.getrlimit(resource.RLIMIT_NOFILE)[1],) * 2)
    bport = free_port()
    backend = start([BACKEND, "1", str(bport)])
    results = {"uptime": open("/proc/uptime").read(), "loadavg": open("/proc/loadavg").read()}
    try:
        measure("c_epoll_copy", lambda l, b: [CPROXY, "-l", str(l), "-b", str(b), "-t", "1", "--io", "epoll", "-m", "copy", "-v"], bport, results)
        measure("c_epoll_hybrid", lambda l, b: [CPROXY, "-l", str(l), "-b", str(b), "-t", "1", "--io", "epoll", "-m", "hybrid", "-v"], bport, results)
        measure("goose", lambda l, b: [GOOSE, "--listen", f"127.0.0.1:{l}", "--to", f"127.0.0.1:{b}", "--workers", "1", "--stat-ms", "3600000"], bport, results)
    finally:
        backend.terminate(); backend.wait()
    out = os.path.join(HERE, "results", f"memory-{time.strftime('%Y%m%d-%H%M%S')}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(results, open(out, "w"), indent=2)
    print("written", out)

if __name__ == "__main__":
    main()
