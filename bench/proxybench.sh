#!/usr/bin/env bash
# proxybench.sh: benchmark of c_proxy against nginx and HAProxy on one Linux box.
#
# Three suites (SUITE=):
#   edge            THE PRODUCTION PATH, shaped like the Docker testbed (../docker): TLS passthrough
#                   routed by SNI to services with several replicas, a peer region as backup, http
#                   health checks (GET /health, 1 s, fall 2 / rise 2), connect timeout 500 ms then the
#                   next server, unknown or missing SNI closed. Every proxy gets that same routing
#                   (proxy.c -R/--check, nginx ssl_preread + upstream backup/max_fails, HAProxy
#                   req.ssl_sni + httpchk/backup); wrk requests https://b.localhost (2 replicas).
#                   Correctness: verify_sni.py, incl. failover through the health checks.
#   sni-plain (default)  THE PRODUCTION ROUTING, PROXY-LIMITED: the edge suite's routing (SNI, replicas,
#                   backup, health checks, connect timeout, unknown SNI closed) without the crypto at the
#                   ends. wrk sends a minimal ClientHello for b.localhost in front of every plain HTTP
#                   request; the backends (backend.c) skip it. The proxies cannot tell: they route on
#                   the first ClientHello and forward the rest as opaque bytes, as with real TLS. With
#                   TLS, wrk and the backends spend their CPU on crypto and every proxy hits their
#                   ceiling; here the proxy is the limit (default WORKERS=1). Correctness: verify.py
#                   with the ClientHello in front of each connection, and the web mix, through the
#                   routing. Every proxy (proxy.c on both engines, nginx, HAProxy) does the same work.
#   tcp             INTERNAL, for visibility only: plain TCP to one backend, no TLS, no routing. Shows
#                   the data path alone; not what production runs. Also BACKEND=nginx.
#
# Compares, in front of the same backends and under the same wrk load:
#   direct          wrk -> backend (no proxy: the ceiling)
#   uring_hybrid    proxy.c default: self-tuning copy <-> inline splice per direction
#   uring_isplice   proxy.c, inline splice (io_uring readiness + splice() on the loop thread)
#   uring_copy      proxy.c, copy only                    (dead end: runs only if named in CONFIGS)
#   epoll_hybrid    proxy.c default data path on its epoll engine (--io epoll: hosts without io_uring)
#   uring_splice    proxy.c, legacy splice via io-wq      (dead end: runs only if named in CONFIGS)
#   nginx           nginx stream (L4) proxy          (if nginx is installed)
#   haproxy         HAProxy TCP mode                 (if haproxy is installed)
#   haproxy_splice  HAProxy TCP mode + splice-auto   (if haproxy is installed)
#
# For every run it records throughput, latency (p50/p90/p99/p99.9), proxy CPU per
# request (task time and whole-core time incl. network softirq), wrk and backend
# utilisation (flags runs where they, not the proxy, are the limit), helper thread
# count, CPU clock and temperature, and, if perf is installed, cycles, IPC,
# syscalls, context switches and cache misses per request.
#
# Runs private instances on ports 18080-18447 (edge backends also on 127.0.0.2-5); system nginx and
# haproxy are untouched.
#
# Usage (proxy.c, backend.c, and optionally verify.py next to this script):
#   sudo ./proxybench.sh
#   sudo QUICK=1 ./proxybench.sh                     # ~3 min smoke run
# Env knobs:
#   WORKERS=2            proxy threads = nginx workers = haproxy threads (sni-plain: 1, proxy-limited)
#   WORKERS=auto         each picks its own count (one per usable CPU); disables auto-pinning
#   SUITE=edge|sni-plain|tcp   see above (SNI=1 = edge, SNI=0 = tcp, kept for old command lines)
#   BACKEND=nginx        tcp suite: backend is nginx 'return 200 "OK\n"' (http keepalive) instead of
#                        backend.c, and adds nginx_same: a stream proxy inside that same nginx
#   SECS=8 ROUNDS=3 WARMUP=1
#   SIZES="11:64 11:512 11:64:close 16384:64 65536:64 1048576:16 mix:64"   bytes:connections[:close]
#                        :close = new connection per request (Connection: close)
#                        mix = web-app page view: 70 requests over HTML/CSS/JS/fonts/images/API JSON
#                        (static files, ~1.8 MB, mean ~26 KB), served by every backend type
#   CONFIGS="direct uring_copy ..."                          subset / order
#   CUSTOM="name:proxy args;name2:args"                      extra proxy.c configs
#   EXTRA="name|procs|port|command"   any other proxy, e.g. your goose build:
#        EXTRA="goose|4|18447|/path/proxy_goose"   ({L}=its port, {B}=backend port in command)
#   PIN=auto|0|1   auto = one physical core per proxy worker, next core backend, rest wrk
#                  (edge: the hyper-threads after the proxy cores are split evenly, backend first)
#   P_CPUS= B_CPUS= W_CPUS=                                  explicit lists, e.g. 0,2  4,5  6,7
#   BACKEND_THREADS= WRK_THREADS=  PERF=auto|0  VERIFY=1|0
#   DEFER=1              TCP_DEFER_ACCEPT on every proxy's listener (proxy.c -A, nginx 'deferred',
#                        HAProxy 'defer-accept'): a client is accepted only once its first data is there
#   TFO=1                TCP Fast Open from proxy to backend (proxy.c -F, HAProxy 'server ... tfo'; nginx's
#                        stream module has no equivalent): the client's first bytes ride in the SYN. Sets
#                        net.ipv4.tcp_fastopen |= 3 for the run (server side for the backends), reverted at
#                        the end. Backends always accept TFO when the host allows it.
#   TRICKS="-F -Q"       adds uring_tricks: proxy.c with its opt-in TCP tricks (-F Fast Open to the backend,
#                        -Q smart ACKs; any proxy.c flags work, e.g. TRICKS="-Q"), and, when -F is in it,
#                        haproxy_tfo (HAProxy's equivalent, 'server ... tfo'; nginx has none) so the comparison
#                        stays fair. Fast Open also sets net.ipv4.tcp_fastopen |= 3 for the run like TFO=1.
#                        TRICKS=0 drops both lines; CONFIGS picks any subset. Default: on.
#   TUNE=1               host tuning for the whole run, reverted at the end (system-wide, so every proxy,
#                        the backend and wrk get it alike):
#                          - CPU exit latency capped at 20 us via /dev/cpu_dma_latency: no C2 (400 us
#                            wakeup on nitro) for the half-idle backend/wrk cores; C1 stays allowed, so idle
#                            hyper-thread siblings do not spin
#                          - net.ipv4.ip_local_port_range 1024-65535 (fewer collisions when proxies connect
#                            to the backend at thousands of connections/s)
#   PROFILE="config:bytes:conns[:close] ..."   after the runs, perf record -g on the proxy cores for that
#                        config and workload; top symbols go to profile-<...>.txt and into the report
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (needed for perf counters, CPU pinning info and package installs)"; exit 1; }
[ -f "$SRC/proxy.c" ] && [ -f "$SRC/backend.c" ] || { echo "proxy.c and backend.c must be next to this script"; exit 1; }

if [ "${QUICK:-0}" = 1 ]; then
  export SECS=${SECS:-3} ROUNDS=${ROUNDS:-1} SIZES=${SIZES:-"11:64 11:64:close 65536:64 1048576:16 mix:64"}
fi

# ---- required packages ----
need=()
command -v gcc >/dev/null     || need+=(build-essential)
command -v wrk >/dev/null     || need+=(wrk)
command -v python3 >/dev/null || need+=(python3)
EDGE=1
{ [ "${SUITE:-}" = tcp ] || [ "${SNI:-}" = 0 ] || { [ -n "${BACKEND:-}" ] && [ "${SUITE:-}" != edge ]; }; } && EDGE=0
[ "$EDGE" = 1 ] && { command -v openssl >/dev/null || need+=(openssl); command -v nginx >/dev/null || need+=(nginx); }
[ -f /usr/include/liburing.h ] || need+=(liburing-dev)
if command -v nginx >/dev/null && nginx -V 2>&1 | grep -q -- '--with-stream=dynamic' \
   && ! ls /usr/lib/nginx/modules/ngx_stream_module.so >/dev/null 2>&1; then need+=(libnginx-mod-stream); fi
if [ ${#need[@]} -gt 0 ]; then
  echo ">> installing: ${need[*]}"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
fi

STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="$PWD/results"; mkdir -p "$RESULTS"
OUT="$RESULTS/proxybench-$STAMP"
# a run stopped early (Ctrl-C, a failed check) still leaves the folder to the user, not to root
[ -n "${SUDO_USER:-}" ] && trap 'chown -R "$SUDO_USER": "$OUT" "$OUT.tar.gz" "$RESULTS" 2>/dev/null' EXIT
WORK="$(mktemp -d /tmp/proxybench.XXXXXX)"
mkdir -p "$OUT"
ulimit -n 65535 2>/dev/null || ulimit -n "$(ulimit -Hn)"

echo ">> building"
gcc -O2 -pthread -o "$WORK/proxy"   "$SRC/main.c" "$SRC/proxy.c" -luring
gcc -O2 -pthread -o "$WORK/backend" "$SRC/backend.c"

# ---- system snapshot (best effort: missing files are fine) ----
set +e +o pipefail
{
  echo "== date";      date -u
  echo "== kernel";    uname -a; grep PRETTY /etc/os-release
  echo "== cpu";       lscpu
  echo "== layout";    lscpu -e=CPU,CORE,SOCKET,MAXMHZ,MINMHZ
  echo "== governor";  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
  echo "== boost";     cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a
  echo "== epp";       cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a
  echo "== profile";   powerprofilesctl get 2>/dev/null || echo n/a
  echo "== ac";        cat /sys/class/power_supply/A*/online 2>/dev/null || echo n/a
  echo "== mitigations"; grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null | sed 's|.*/||'
  echo "== cmdline";   cat /proc/cmdline
  echo "== mem";       free -m
  echo "== load";      uptime
  echo "== top cpu users"; ps -eo pcpu,comm --sort=-pcpu | head -8
  echo "== sysctl";    sysctl net.core.somaxconn net.ipv4.tcp_congestion_control net.core.default_qdisc \
                              fs.pipe-max-size kernel.io_uring_disabled kernel.perf_event_paranoid 2>/dev/null
  echo "== versions"
  gcc --version | head -1
  dpkg-query -W -f='liburing-dev ${Version}\n' liburing-dev 2>/dev/null || true
  wrk -v 2>&1 | head -1 || true
  nginx -v 2>&1 || echo "nginx: not installed"
  haproxy -v 2>/dev/null | head -1 || echo "haproxy: not installed"
} >"$OUT/sysinfo.txt" 2>&1
set -e -o pipefail

# ---- the orchestrator ----
cat >"$WORK/bench.py" <<'PY'
import glob, json, os, re, shutil, signal, socket, statistics as st, subprocess, sys, threading, time

E = os.environ
WORK, OUT, SRC = E["WORK"], E["OUT"], E["SRC"]
# SUITE=sni-plain (default): the production routing, proxy-limited. SUITE=edge: the same with real TLS
# (crypto-bound: every proxy ties). SUITE=tcp: the internal single-backend TCP suite.
SUITE = E.get("SUITE") or ("edge" if E.get("SNI") == "1" else
                           "tcp" if E.get("SNI") == "0" or "BACKEND" in E else "sni-plain")
W_RAW = E.get("WORKERS", "1" if SUITE == "sni-plain" else "2").strip()
AUTO = W_RAW == "auto"
W = 0 if AUTO else int(W_RAW)
BACKEND = E.get("BACKEND", "builtin")
SECS = int(E.get("SECS", "8")); ROUNDS = int(E.get("ROUNDS", "3")); WARM = float(E.get("WARMUP", "1"))
DEF_SIZES = ("3:64 3:512 3:64:close mix:64" if BACKEND == "nginx"
             else "11:64 11:512 11:64:close 16384:64 65536:64 1048576:16 mix:64")
def parse_size(t):
    f = t.split(":")
    return (f[0] if f[0] == "mix" else int(f[0]), int(f[1]), len(f) > 2 and f[2] == "close")

# ---- web mix: one "page view" of a typical web app, 70 requests, each path once per cycle ----
# Shaped after the HTTP Archive Web Almanac 2024 (page-weight chapter): median page ~66-71 requests,
# JavaScript the most requested type (~23), then images (~18); median desktop page ~2.6 MB, ~40% of it
# images. Sizes are skewed like real sites: many small files, a few large bundles and photos.
# Total ~1.8 MB per cycle, mean ~26 KB per request, median ~10 KB.
def _mix():
    m = []
    def add(fmt, count, size):
        for i in range(count):
            m.append((fmt.format(i), size))
    add("/index{}.html", 1, 32 << 10); add("/about{}.html", 1, 18 << 10)            # HTML      2
    add("/static/css/app{}.css", 1, 30 << 10); add("/static/css/vendor{}.css", 2, 15 << 10)
    add("/static/css/page{}.css", 4, 4 << 10)                                         # CSS       7
    add("/static/js/main{}.js", 1, 250 << 10); add("/static/js/vendor{}.js", 1, 120 << 10)
    add("/static/js/chunk{}.js", 4, 40 << 10); add("/static/js/module{}.js", 8, 10 << 10)
    add("/static/js/snippet{}.js", 9, 3 << 10)                                        # JS       23
    add("/static/fonts/text{}.woff2", 2, 30 << 10); add("/static/fonts/head{}.woff2", 1, 45 << 10)  # fonts 3
    add("/static/img/icon{}.svg", 6, 1536); add("/static/img/thumb{}.webp", 6, 12 << 10)
    add("/static/img/photo{}.jpg", 4, 70 << 10); add("/static/img/hero{}.jpg", 1, 300 << 10)
    add("/static/img/banner{}.webp", 1, 180 << 10)                                    # images   18
    add("/api/small{}.json", 6, 512); add("/api/list{}.json", 6, 2 << 10)
    add("/api/detail{}.json", 4, 8 << 10); add("/api/feed{}.json", 1, 40 << 10)      # API/XHR  17
    return m
MIX = _mix()
MIX_MEAN = sum(s for _, s in MIX) / len(MIX)
SIZES = [parse_size(t) for t in E.get("SIZES", DEF_SIZES).split()]
PIN, PERF, VERIFY = E.get("PIN", "auto"), E.get("PERF", "auto"), E.get("VERIFY", "1")
BPORT, UPORT, NPORT, HPORT, SPORT = 18080, 18443, 18444, 18445, 18446
if SUITE not in ("edge", "sni-plain", "tcp"):
    print(f"error: SUITE={SUITE}: want edge, sni-plain or tcp"); sys.exit(1)
SNI = SUITE in ("edge", "sni-plain")        # the edge routing: SNI, replicas, backup, checks
TLS = SUITE == "edge"                       # real TLS at the ends (sni-plain: a ClientHello, then plain HTTP)
DEFER = E.get("DEFER", "0") == "1"
TFO = E.get("TFO", "0") == "1"
TRICKS = E.get("TRICKS", "-F -Q").split()
TRICKS = [] if TRICKS in ([], ["0"]) else TRICKS
TRICKS_TFO = "-F" in TRICKS
TUNE = E.get("TUNE", "0") == "1"
PROFILE = [parse_size(t.split(":", 1)[1]) + (t.split(":", 1)[0],) for t in E.get("PROFILE", "").split()]
if SNI:
    if BACKEND != "builtin":
        print("error: the edge suites bring their own backends; drop BACKEND (or SUITE=tcp)"); sys.exit(1)
    BACKEND = "tls-nginx" if TLS else "builtin-sni"
    # Shaped like one region of the Docker testbed (../docker, haproxy.cfg): replicas share a port on
    # their own addresses (127.0.0.x needs no setup on Linux), health checks go to a side port.
    BPORT, BPORT_B, PEER_A, PEER_B, HCPORT = 18081, 18082, 18085, 18084, 18090
    A_IP, B1_IP, B2_IP, PEER_IP = "127.0.0.2", "127.0.0.3", "127.0.0.4", "127.0.0.5"
    EDGE = {"a": ([(A_IP, BPORT)], (PEER_IP, PEER_A)),                         # service: (local servers, backup)
            "b": ([(B1_IP, BPORT_B), (B2_IP, BPORT_B)], (PEER_IP, PEER_B))}
    HOST, TARGET = "b.localhost", 18082    # wrk asks for b (2 replicas); direct = replica b1, also on 127.0.0.1
else:
    HOST, TARGET = "127.0.0.1", BPORT
VERIFY_SIZES = (0, 1, 11, 4096, 16384, 65535, 65536, 65537, 300000, 1 << 20, 16 << 20)   # verify_sni.py's files
HZ = os.sysconf("SC_CLK_TCK")
REPORT = []

def log(*a):
    print(*a, flush=True)

def die(m):
    log("error:", m); sys.exit(1)

# ------------------------------------------------------------ topology ----
def parse_cpus(s):
    out = []
    for part in s.replace(" ", "").split(","):
        if "-" in part:
            a, b = part.split("-"); out += range(int(a), int(b) + 1)
        elif part:
            out.append(int(part))
    return out

def physical_cores():
    allowed = os.sched_getaffinity(0)
    groups = {}
    for line in subprocess.run(["lscpu", "-p=CPU,CORE,SOCKET"], capture_output=True, text=True).stdout.splitlines():
        if line.startswith("#"):
            continue
        cpu, core, sock = line.split(",")[:3]
        if int(cpu) in allowed:
            groups.setdefault((sock, core), []).append(int(cpu))
    return sorted((sorted(v) for v in groups.values()), key=lambda v: v[0])

CORES = physical_cores()
P_CPUS = B_CPUS = W_CPUS = None
if E.get("P_CPUS"):
    if not (E.get("B_CPUS") and E.get("W_CPUS")):
        die("P_CPUS needs B_CPUS and W_CPUS too")
    P_CPUS, B_CPUS, W_CPUS = (parse_cpus(E[k]) for k in ("P_CPUS", "B_CPUS", "W_CPUS"))
elif PIN in ("auto", "1") and not AUTO:
    if len(CORES) >= W + 2:
        P_CPUS = [c[0] for c in CORES[:W]]                 # one hyper-thread per physical core, sibling left idle
        if TLS:
            # TLS: backend and wrk both pay for crypto, so split the remaining hyper-threads evenly
            # (nitro, WORKERS=1: backend 2,3,4 / wrk 5,6,7). With one physical core each, both were
            # saturated before the proxy was, so the proxies could not be told apart.
            rest = [x for c in CORES[W:] for x in c]
            B_CPUS, W_CPUS = rest[:(len(rest) + 1) // 2], rest[(len(rest) + 1) // 2:]
        else:
            B_CPUS = CORES[W]
            W_CPUS = [x for c in CORES[W + 1:] for x in c]
    elif PIN == "1":
        die(f"PIN=1 needs WORKERS+2={W+2} physical cores, found {len(CORES)}")
PINNED = P_CPUS is not None
# effective worker count. nginx "auto" counts ALL online CPUs and ignores taskset, while proxy.c and
# HAProxy count only the CPUs they may run on, so under pinning nginx gets an explicit number.
W_EFF = (len(P_CPUS) if PINNED else len(os.sched_getaffinity(0))) if AUTO else W
NGX_W = "auto" if (AUTO and not PINNED) else str(W_EFF)
BT = int(E.get("BACKEND_THREADS") or (len(B_CPUS) if PINNED else W_EFF))
WT = int(E.get("WRK_THREADS") or (len(W_CPUS) if PINNED else 2))

def aff(cpus):
    return (lambda: os.sched_setaffinity(0, cpus)) if cpus else None

# ----------------------------------------------------------- l2 sizing ----
def l2_bytes():
    for d in glob.glob("/sys/devices/system/cpu/cpu0/cache/index*"):
        try:
            if open(d + "/level").read().strip() == "2":
                m = re.match(r"(\d+)([KMG]?)", open(d + "/size").read().strip())
                return int(m.group(1)) * {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30}[m.group(2)]
        except OSError:
            pass
    return 512 << 10
L2 = l2_bytes()
L2N = max(8, 1 << ((L2 // 16384).bit_length() - 1))   # 16 KiB buffers: enough of them for many conns

# -------------------------------------------------------------- configs ----
PROXY = WORK + "/proxy"
# edge: the same routing every proxy gets: round-robin over the local servers, the peer as backup,
# http health checks (1 s, fall 2 / rise 2), connect timeout 500 ms then the next server, no default
# route (unknown or missing SNI is closed)
SNI_ROUTES = ([a for svc, (srv, bk) in EDGE.items() for a in
               ("-R", f"{svc}.localhost=" + ",".join(f"{ip}:{pt}" for ip, pt in srv) + f",backup={bk[0]}:{bk[1]}")]
              + ["--connect-timeout", "500", "--check", f"http:{HCPORT}/health",
                 "--backup-check", f"http:{HCPORT}/health"]) if SNI else []
def ours(extra):
    return ([PROXY, "-l", str(UPORT)] + ([] if SNI else ["-b", str(BPORT)]) + ([] if AUTO else ["-t", str(W)]) + SNI_ROUTES
            + (["-A"] if DEFER else []) + (["-F"] if TFO else []) + extra)
# uring_* insist on io_uring (no silent epoll fallback); epoll_* force the epoll engine

CFG = {
    "direct":        dict(port=TARGET, argv=None),
    "uring_hybrid":  dict(port=UPORT, argv=ours(["--io", "uring", "-m", "hybrid", "-v"]), ours=True),
    **({"uring_tricks": dict(port=UPORT, argv=ours(["--io", "uring", "-m", "hybrid", "-v"] + TRICKS), ours=True)} if TRICKS else {}),
    "uring_isplice": dict(port=UPORT, argv=ours(["--io", "uring", "-m", "isplice", "-v"]), ours=True),
    "uring_copy":    dict(port=UPORT, argv=ours(["--io", "uring", "-m", "copy", "-v"]), ours=True),
    "uring_splice":  dict(port=UPORT, argv=ours(["--io", "uring", "-m", "splice", "-v"]), ours=True),
    "epoll_hybrid":  dict(port=UPORT, argv=ours(["--io", "epoll", "-m", "hybrid", "-v"]), ours=True),
}
NOTES = []

nginx = shutil.which("nginx")
mod = ""
if nginx:
    v = subprocess.run([nginx, "-V"], capture_output=True, text=True).stderr
    mod = ""
    if "--with-stream=dynamic" in v:
        for f in ("/usr/lib/nginx/modules/ngx_stream_module.so", "/usr/share/nginx/modules/ngx_stream_module.so"):
            if os.path.exists(f):
                mod = f"load_module {f};"; break
        else:
            nginx = None; NOTES.append("nginx skipped: stream module missing (apt install libnginx-mod-stream)")
    elif "--with-stream" not in v:
        nginx = None; NOTES.append("nginx skipped: built without stream module")
    if nginx:
        if SNI:
            # nginx OSS has no active health checks: max_fails=1 marks a server down for fail_timeout
            # after a failed connect (passive), and proxy_next_upstream moves on to the next one
            ups = "\n".join(f"    upstream {svc} {{\n" + "".join(f"        server {ip}:{pt} max_fails=1 fail_timeout=2s;\n"
                                                         for ip, pt in srv)
                            + f"        server {bk[0]}:{bk[1]} backup;\n    }}" for svc, (srv, bk) in EDGE.items())
            upstreams = f"""    map $ssl_preread_server_name $sni_up {{
        hostnames;
        a.localhost a;
        b.localhost b;
        default     reject;
    }}
{ups}
    upstream reject {{ server 127.0.0.1:1; }}   # unknown or missing SNI: refused, so the client is closed"""
            route = ("ssl_preread on;\n        preread_timeout 5s;\n        proxy_pass $sni_up;\n"
                     "        proxy_next_upstream on;\n        proxy_next_upstream_tries 3;")
        else:
            upstreams = f"    upstream be {{ server 127.0.0.1:{BPORT}; }}"
            route = "proxy_pass be;"
        open(WORK + "/nginx.conf", "w").write(f"""{mod}
user root;
worker_processes {NGX_W};
worker_rlimit_nofile 65535;
daemon off;
pid {WORK}/nginx.pid;
error_log {WORK}/nginx_error.log warn;
events {{ worker_connections 16384; multi_accept on; }}
stream {{
{upstreams}
    server {{
        listen 127.0.0.1:{NPORT} reuseport{" deferred" if DEFER else ""};
        {route}
        proxy_buffer_size 128k;    # tuned: +18% at 64 KiB vs 64k (+7% for 64k vs 32k), small unchanged
        proxy_half_close on;       # keep the other direction open after one side sends FIN (like the others)
        tcp_nodelay on;
        proxy_connect_timeout {"500ms" if SNI else "5s"};
        proxy_timeout 60s;
    }}
}}
""")
        CFG["nginx"] = dict(port=NPORT, argv=[nginx, "-p", WORK, "-e", WORK + "/nginx_error.log", "-c", WORK + "/nginx.conf"])
else:
    NOTES.append("nginx not installed: skipped")

# static tree for every backend: the web mix's files (+ numbered pattern files for the TLS backends).
# Content is the i % 251 pattern, so a proxy that corrupts or reorders bytes is caught by the mix check.
WWW = WORK + "/www"
PAT = bytes(range(251))
def pattern(n):
    return (PAT * (n // 251 + 1))[:n]
for path, size in MIX:
    os.makedirs(os.path.dirname(WWW + path), exist_ok=True)
    open(WWW + path, "wb").write(pattern(size))
# nginx backends: static serving as an operator would set it up (sendfile, cached opens, real types)
NGX_STATIC = f"""    sendfile on;
    tcp_nopush on;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 60s;
    types {{ text/html html; text/css css; application/javascript js; application/json json;
             image/svg+xml svg; image/webp webp; image/jpeg jpg; font/woff2 woff2; }}
    default_type application/octet-stream;"""

if BACKEND == "nginx":
    if not nginx:
        die("BACKEND=nginx needs nginx with the stream module")
    BW = "auto" if (AUTO and not PINNED) else str(BT)
    open(WORK + "/backend_nginx.conf", "w").write(f"""{mod}
user root;
worker_processes {BW};
worker_rlimit_nofile 65535;
daemon off;
pid {WORK}/backend_nginx.pid;
error_log {WORK}/backend_nginx_error.log warn;
events {{ worker_connections 10240; }}
http {{
    access_log off;
    keepalive_requests 1000000;
    keepalive_timeout 65s;
{NGX_STATIC}
    server {{
        listen 127.0.0.1:{BPORT};
        root {WWW};
        location / {{ try_files $uri @ok; }}       # the web mix's static files, else "OK"
        location @ok {{ return 200 "OK\\n"; }}
    }}
}}
stream {{
    server {{
        listen 127.0.0.1:{SPORT};
        proxy_pass 127.0.0.1:{BPORT};
    }}
}}
""")
    BACKEND_ARGV = [nginx, "-p", WORK, "-e", WORK + "/backend_nginx_error.log", "-c", WORK + "/backend_nginx.conf"]
    CFG["nginx_same"] = dict(port=SPORT, argv=None, shared=True)   # stream proxy living inside the backend nginx
    NOTES.append(f"BACKEND=nginx: backend is nginx 'return 200 OK' ({BW} workers) plus the web mix's static files "
                 "(sendfile); numeric response sizes in SIZES are ignored; nginx_same = your exact config (stream proxy "
                 "inside the backend's workers); only the web-mix check runs (verify.py needs backend.c)")
elif SNI and not TLS:
    # sni-plain: backend.c on every replica / peer address and health port; it skips the ClientHello
    addrs = [f"{ip}:{pt}" for svc, (srv, bk) in EDGE.items() for ip, pt in srv + [bk]]
    addrs += [f"127.0.0.1:{BPORT_B}"] + [f"{ip}:{HCPORT}" for ip in (A_IP, B1_IP, B2_IP, PEER_IP)]
    BACKEND_ARGV = [WORK + "/backend", str(BT), ",".join(dict.fromkeys(addrs)), WWW]
    NOTES.append(f"sni-plain suite: the edge routing (a.localhost -> {A_IP}:{BPORT}; b.localhost -> replicas "
                 f"{B1_IP}:{BPORT_B} + {B2_IP}:{BPORT_B}, peer {PEER_IP} as backup, http checks on :{HCPORT}, connect "
                 "timeout 500 ms, unknown SNI closed) with no crypto at the ends: wrk sends a 72-byte ClientHello for "
                 f"{HOST} in front of every plain HTTP request (a real browser's is ~1.5 KB, once per connection), "
                 "backend.c skips it. The proxy is the limit here; SUITE=edge is the same path with real TLS")
elif SNI:
    if not nginx:
        die("the edge suite needs nginx (TLS backends); SUITE=tcp runs without")
    BW = "auto" if (AUTO and not PINNED) else str(BT)
    for n in sorted(set(VERIFY_SIZES) | {s for s, _, _ in SIZES if s != "mix"}):
        open(f"{WWW}/{n}", "wb").write(pattern(n))
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-days", "7", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:a.localhost,DNS:b.localhost",
                    "-keyout", WORK + "/key.pem", "-out", WORK + "/cert.pem"], check=True, capture_output=True)
    def edge_server(inst, who, ip, port, extra_listen=""):
        return (f"    server {{ listen {ip}:{port} ssl reuseport fastopen=4096;{extra_listen} root {WWW};\n"
                f"             location = /who {{ return 200 \"{who}\\n\"; }} location = /inst {{ return 200 \"{inst}\\n\"; }} }}\n")
    EDGE_SERVERS = (edge_server("a", "a", A_IP, BPORT)
                    + edge_server("b1", "b", B1_IP, BPORT_B, f" listen 127.0.0.1:{BPORT_B} ssl reuseport fastopen=4096;")
                    + edge_server("b2", "b", B2_IP, BPORT_B)
                    + edge_server("peer", "a", PEER_IP, PEER_A) + edge_server("peer", "b", PEER_IP, PEER_B)
                    + "".join(f"    server {{ listen {ip}:{HCPORT}; open_file_cache off; location = /health {{ if (-f {WORK}/unhealthy_{inst}) "
                              f"{{ return 503 \"down\\n\"; }} return 200 \"ok\\n\"; }} }}\n"
                              for inst, ip in (("a", A_IP), ("b1", B1_IP), ("b2", B2_IP), ("peer", PEER_IP))))
    open(WORK + "/backend_tls.conf", "w").write(f"""user root;
worker_processes {BW};
worker_rlimit_nofile 65535;
daemon off;
pid {WORK}/backend_tls.pid;
error_log {WORK}/backend_tls_error.log warn;
events {{ worker_connections 16384; }}
http {{
    access_log off;
    tcp_nodelay on;
    keepalive_requests 1000000;
    keepalive_timeout 65s;
    ssl_certificate     {WORK}/cert.pem;
    ssl_certificate_key {WORK}/key.pem;
    # cheaper handshakes for backend and wrk (+11% ceiling on nitro). The client still offers its
    # X25519MLKEM768 share, so the ClientHello the proxies parse stays full size (~1.5 KB), and it
    # also sends an X25519 share, so there is no HelloRetryRequest.
    ssl_ecdh_curve X25519;
{NGX_STATIC}
    # /who = the service, /inst = the instance (replica or peer). /health on the side port answers 503
    # while {WORK}/unhealthy_<instance> exists (the failover checks flip it)
{EDGE_SERVERS}
}}
""")
    BACKEND_ARGV = [nginx, "-p", WORK, "-e", WORK + "/backend_tls_error.log", "-c", WORK + "/backend_tls.conf"]
    NOTES.append(f"edge suite (the production path, as in ../docker): TLS passthrough routed by SNI. a.localhost -> "
                 f"{A_IP}:{BPORT}; b.localhost -> replicas {B1_IP}:{BPORT_B} + {B2_IP}:{BPORT_B} round-robin; each has the "
                 f"peer {PEER_IP} as backup; http health checks (GET /health on :{HCPORT}, 1 s, fall 2 / rise 2; "
                 "nginx OSS has none: passive max_fails only); connect timeout 500 ms, then the next server; unknown "
                 f"or missing SNI closed. Backends: nginx https ({BW} workers, ECDSA P-256). wrk requests https://{HOST}; "
                 "direct = wrk -> replica b1. ':close' sizes = a full TLS handshake per request, where wrk and the proxy "
                 "saturate together on a 4-core box: compare core us there, not req/s")
else:
    BACKEND_ARGV = [WORK + "/backend", str(BT), str(BPORT), WWW]

haproxy = shutil.which("haproxy")
import resource
HAP_MAXCONN = max(1000, min(20000, (resource.getrlimit(resource.RLIMIT_NOFILE)[0] - 200) // 4))   # /4: splice mode also reserves pipe fds
HTFO = " tfo" if TFO else ""
def hap_route(tfo):
    # with tfo, HAProxy wants retries for failures it cannot see before the SYN data is gone
    retry = "    retry-on conn-failure empty-response response-timeout\n" if tfo else ""
    if SNI:
        # as ../docker/haproxy/haproxy.cfg: http checks, a failed connect on live traffic marks the
        # server down (observe layer4), the peer as backup, no default_backend (unknown SNI closed)
        obs = "observe layer4 error-limit 1 on-error mark-down"
        backends = ""
        for svc, (srv, bk) in EDGE.items():
            backends += (f"backend {svc}\n    option httpchk\n"
                         f"    http-check send meth GET uri /health ver HTTP/1.1 hdr Host {svc}.localhost\n{retry}")
            for i, (ip, pt) in enumerate(srv):
                backends += f"    server {svc}{i + 1} {ip}:{pt} check port {HCPORT} {obs}{tfo}\n"
            backends += f"    server peer {bk[0]}:{bk[1]} check port {HCPORT} backup {obs}{tfo}\n"
        return f"""    tcp-request inspect-delay 5s
    tcp-request content accept if {{ req_ssl_hello_type 1 }}
    use_backend a if {{ req.ssl_sni -i a.localhost }}
    use_backend b if {{ req.ssl_sni -i b.localhost }}
{backends}"""
    return f"""    default_backend b
backend b
{retry}    server s1 127.0.0.1:{BPORT}{tfo}
"""
HAP_EDGE_DEFAULTS = """    timeout connect 500ms
    timeout check 1s
    retries 3
    option redispatch 1
    default-server inter 1s fastinter 250ms downinter 1s fall 2 rise 2
"""
if haproxy:
    hap_cfgs = [("haproxy", "", HTFO), ("haproxy_splice", "    option splice-auto\n", HTFO)]
    if TRICKS_TFO:
        hap_cfgs.insert(1, ("haproxy_tfo", "", " tfo"))     # HAProxy's side of uring_tricks
    for name, extra, tfo in hap_cfgs:
        open(f"{WORK}/{name}.cfg", "w").write(f"""global
{"" if AUTO else f"    nbthread {W}" + chr(10)}    maxconn {HAP_MAXCONN}
    tune.bufsize 65536             # tuned: +18% at 64 KiB and +8% on the web mix vs 32768
defaults
    mode tcp
{HAP_EDGE_DEFAULTS if SNI else "    timeout connect 5s" + chr(10)}    timeout client 60s
    timeout server 60s
    # tuned as an operator would for client-speaks-first traffic (HTTP, TLS): delay the handshake ACK
    # to the server and the request ACK to the client so both ride on data. Off by default in TCP mode
    # only because server-speaks-first protocols could stall. Measured: +11% new connections/s.
    option tcp-smart-accept
    option tcp-smart-connect
{extra}frontend f
    bind 127.0.0.1:{HPORT}{" defer-accept" if DEFER else ""}
{hap_route(tfo)}""")
        CFG[name] = dict(port=HPORT, argv=[haproxy, "-db", "-f", f"{WORK}/{name}.cfg"])
else:
    NOTES.append("haproxy not installed: skipped (sudo apt install haproxy)")

XPORT = 18447
for item in filter(None, (x.strip() for x in E.get("EXTRA", "").split(";"))):
    try:
        name, procs, port, cmd = (v.strip() for v in item.split("|", 3))
        procs, port = int(procs), int(port)
    except ValueError:
        die(f"bad EXTRA entry {item!r}; want name|procs|port|command")
    cmd = cmd.replace("{L}", str(port)).replace("{B}", str(BPORT))
    CFG[name] = dict(port=port, argv=["sh", "-c", f"for i in $(seq {procs}); do {cmd} & done; wait"], external=True)
    NOTES.append(f"{name}: {procs} x '{cmd}' on port {port}")

for item in filter(None, (x.strip() for x in E.get("CUSTOM", "").split(";"))):
    name, args = item.split(":", 1)
    CFG[name.strip()] = dict(port=UPORT, argv=ours(args.split()), ours=True)

# dead ends: the code stays (proxy.c modes, configs above) but they only run when named in CONFIGS
#   uring_splice  io_uring OP_SPLICE via io-wq: always <= uring_isplice when proxy-bound, terrible in VMs
#   uring_copy    copy only: hybrid matches it on small traffic and beats it 1.8-4.4x on bulk
DEFAULT_SKIP = ["uring_copy", "uring_splice"]
SKIPPED = []
if E.get("CONFIGS", "").split():
    ORDER = E["CONFIGS"].split()
else:
    ORDER = [k for k in CFG if k not in DEFAULT_SKIP]
    SKIPPED = [k for k in CFG if k in DEFAULT_SKIP]
    if SKIPPED:
        NOTES.append(f"skipped by default (dead ends): {' '.join(SKIPPED)}; include them with "
                     f"CONFIGS=\"{' '.join(ORDER + SKIPPED)}\"")
for k in ORDER:
    if k not in CFG:
        die(f"unknown config {k}; available: {' '.join(CFG)}")

# ------------------------------------------------------------- perf -------
def find_perf():
    cands = [shutil.which("perf")] + sorted(glob.glob("/usr/lib/linux-tools/*/perf"), reverse=True)
    for p in filter(None, cands):
        r = subprocess.run([p, "stat", "-x,", "-e", "task-clock", "--", "true"], capture_output=True, text=True)
        if r.returncode == 0 and "task-clock" in r.stderr:
            return p
    return None

PERF_BIN, PERF_EV = None, []
if PERF != "0":
    PERF_BIN = find_perf()
    if PERF_BIN:
        for ev in ("cycles", "instructions", "cache-misses", "context-switches", "raw_syscalls:sys_enter"):
            r = subprocess.run([PERF_BIN, "stat", "-x,", "-e", ev, "--", "sleep", "0.05"], capture_output=True, text=True)
            if r.returncode == 0 and "<not supported>" not in r.stderr and "<not counted>" not in r.stderr:
                PERF_EV.append(ev)
        if not PERF_EV:
            PERF_BIN = None
    if not PERF_BIN:
        NOTES.append("perf not usable: no cycle/syscall counters (install: sudo apt install linux-tools-common linux-tools-$(uname -r))")
    elif len(PERF_EV) < 5:
        NOTES.append("perf: unsupported events skipped: " + ", ".join(e for e in ("cycles", "instructions", "cache-misses", "context-switches", "raw_syscalls:sys_enter") if e not in PERF_EV))

def perf_run(pids, secs, out):
    tgt = ["-C", ",".join(map(str, P_CPUS))] if PINNED else ["-p", ",".join(map(str, pids))]
    r = subprocess.run([PERF_BIN, "stat", "-x,", "-e", ",".join(PERF_EV)] + tgt + ["--", "sleep", str(secs)],
                       capture_output=True, text=True)
    for line in r.stderr.splitlines():
        f = line.split(",")
        if len(f) > 2 and f[0] and f[0][0].isdigit():
            out[f[2].split(":u")[0]] = float(f[0])

# ------------------------------------------------------------ /proc --------
def children(pid):
    out, i = [pid], 0
    while i < len(out):
        try:
            for t in os.listdir(f"/proc/{out[i]}/task"):
                out += [int(x) for x in open(f"/proc/{out[i]}/task/{t}/children").read().split()]
        except OSError:
            pass
        i += 1
    return out

def ticks(pids):
    u = s = 0
    for p in pids:
        try:
            f = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()
            u += int(f[11]); s += int(f[12])
        except OSError:
            pass
    return u, s

def nthreads(pids):
    n = 0
    for p in pids:
        try:
            n += len(os.listdir(f"/proc/{p}/task"))
        except OSError:
            pass
    return n

def cpustat():
    d = {}
    for line in open("/proc/stat"):
        if line.startswith("cpu") and line[3].isdigit():
            f = line.split()
            d[int(f[0][3:])] = [int(x) for x in f[1:8]]   # user nice system idle iowait irq softirq
    return d

def cpu_split(a, b, cpus):
    tot = busy = sirq = sysx = usr = 0
    for c in cpus:
        x = [j - i for i, j in zip(a[c], b[c])]
        t = sum(x); tot += t
        busy += t - x[3] - x[4]; sirq += x[6] + x[5]; sysx += x[2]; usr += x[0] + x[1]
    if not tot:
        return 0, 0, 0, 0
    return busy / tot, usr / tot, sysx / tot, sirq / tot

def freq_mhz(cpus):
    v = []
    for c in cpus:
        try:
            v.append(int(open(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq").read()) / 1000)
        except OSError:
            pass
    return sum(v) / len(v) if v else 0

TEMP_FILE = None
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        if open(h + "/name").read().strip() in ("k10temp", "zenpower", "coretemp"):
            TEMP_FILE = h + "/temp1_input"; break
    except OSError:
        pass
if not TEMP_FILE:
    z = sorted(glob.glob("/sys/class/thermal/thermal_zone*/temp"))
    TEMP_FILE = z[0] if z else None

def temp_c():
    try:
        return int(open(TEMP_FILE).read()) / 1000 if TEMP_FILE else 0
    except OSError:
        return 0

class Sampler(threading.Thread):
    def __init__(self, pid, cpus):
        super().__init__(daemon=True)
        self.pid, self.cpus, self.stop = pid, cpus, threading.Event()
        self.maxthr, self.mhz, self.temp = 0, [], []
    def run(self):
        while not self.stop.wait(0.25):
            if self.pid:
                self.maxthr = max(self.maxthr, nthreads(children(self.pid)))
            self.mhz.append(freq_mhz(self.cpus)); self.temp.append(temp_c())

# ------------------------------------------------------------- servers ----
import struct
def client_hello(name):
    """A minimal TLS ClientHello record carrying only server_name: what an SNI proxy routes on."""
    sni = name.encode()
    ext = struct.pack(">HHHBH", 0, len(sni) + 5, len(sni) + 3, 0, len(sni)) + sni
    body = b"\x03\x03" + bytes(32) + b"\x00" + b"\x00\x02\x13\x01" + b"\x01\x00" + struct.pack(">H", len(ext)) + ext
    hs = b"\x01" + struct.pack(">I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs
HELLO = client_hello(HOST) if SNI and not TLS else b""

if TLS:
    import ssl
    TLS_CTX = ssl.create_default_context()
    TLS_CTX.check_hostname = False
    TLS_CTX.verify_mode = ssl.CERT_NONE

def http_ok(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1) as s:
            if TLS:
                s = TLS_CTX.wrap_socket(s, server_hostname=HOST)
            s.sendall(HELLO + b"GET /11 HTTP/1.1\r\nHost: x\r\n\r\n")
            return s.recv(64).startswith(b"HTTP/1.1 200")
    except OSError:
        return False

def port_open(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.3).close(); return True
    except OSError:
        return False

def start(name, tag=""):
    c = CFG[name]
    if c["argv"] is None:
        return None
    with open(f"{OUT}/logs/{name}.log", "a") as lf:
        lf.write(f"### RUN {tag}\n")
    p = subprocess.Popen(c["argv"], stdout=open(f"{OUT}/logs/{name}.log", "a"), stderr=subprocess.STDOUT,
                         preexec_fn=aff(P_CPUS), start_new_session=True)
    for _ in range(100):
        if http_ok(c["port"]):
            return p
        if p.poll() is not None:
            break
        time.sleep(0.05)
    kill_group(p); die(f"{name} did not start (see {OUT}/logs/{name}.log)")

def kill_group(p, sig=signal.SIGTERM):
    try:
        os.killpg(p.pid, sig)
    except OSError:
        pass

def stop(p, port):
    if not p:
        return
    kill_group(p)
    try:
        p.wait(5)
    except subprocess.TimeoutExpired:
        kill_group(p, signal.SIGKILL); p.wait()
    for _ in range(60):
        if not port_open(port):
            return
        time.sleep(0.05)

def proxy_counters(name, tag):
    """Sum the 'final [wN] key=val' lines proxy.c -v prints at exit, for one run."""
    try:
        txt = open(f"{OUT}/logs/{name}.log").read()
    except OSError:
        return {}
    part = txt.rsplit(f"### RUN {tag}\n", 1)[-1]
    tot = {}
    for line in part.splitlines():
        if line.startswith("final [w"):
            for kv in line.split()[2:]:
                k, _, v = kv.partition("=")
                if v.isdigit():
                    tot[k] = tot.get(k, 0) + int(v)
    return tot

LUA = WORK + "/report.lua"
open(LUA, "w").write("""
done = function(s, lat, req)
  io.write(string.format("@@R %d %d %d %d %d %d %d %d\\n", s.requests, s.duration, s.bytes,
    s.errors.connect, s.errors.read, s.errors.write, s.errors.status, s.errors.timeout))
  for _, p in ipairs({50, 90, 99, 99.9}) do io.write(string.format("@@P %g %d\\n", p, lat:percentile(p))) end
  io.write(string.format("@@M %.0f %d\\n", lat.mean, lat.max))
end
""")
# web mix: the same report hook plus a request() that walks the page view; each wrk thread starts at a
# different offset, so concurrent connections hit different files, like browsers on different pages
# sni-plain: every request goes out behind the ClientHello (wrk has no per-connection hook; after the
# first one per connection it is 72 opaque bytes, the same for every config, direct included). wrk
# checks the first request of thread 0 at startup (one request() call, which must be plain HTTP), so
# that thread skips the prefix exactly once (`skip`); every request on the wire carries it. HELLO is a
# script constant in every thread's state (thread:set would cut the string at its first NUL byte)
LUA_HELLO = ("local HELLO = \"" + "".join("\\%d" % b for b in HELLO) + "\"\nlocal first = 1\n"
             "local function pre() if skip == 1 then skip = 0; return \"\" end return HELLO end\n")
if HELLO:
    open(LUA, "a").write(LUA_HELLO + "setup = function(thread) thread:set(\"skip\", first); first = 0 end\n"
                         "request = function() return pre() .. wrk.format() end\n")
MIX_LUA = WORK + "/mix.lua"
open(MIX_LUA, "w").write(open(LUA).read().split("request = function")[0] + """
local paths = {""" + ",".join('"%s"' % p for p, _ in MIX) + """}
local n = 0
local tid = 0
setup = function(thread) thread:set("start", tid * 17); tid = tid + 1""" + ("; thread:set(\"skip\", first); first = 0" if HELLO else "") + """ end
init = function(args) n = tonumber(start) or 0 end
request = function()
  n = n + 1
  return """ + ("pre() .. " if HELLO else "") + """wrk.format(nil, paths[(n % #paths) + 1])
end
""")

def run_wrk(port, size, conns, secs, close=False):
    path = WORK + "/wrk.out"
    with open(path, "w") as f:
        p = subprocess.Popen(["wrk", f"-t{min(WT, conns)}", f"-c{conns}", f"-d{secs}s", "--timeout", "5s",
                              "-s", MIX_LUA if size == "mix" else LUA] + (["-H", "Connection: close"] if close else []) +
                             [f"{'https' if TLS else 'http'}://{HOST}:{port}/{'' if size == 'mix' else size}"],
                             stdout=f, stderr=subprocess.STDOUT, preexec_fn=aff(W_CPUS))
        _, _, ru = os.wait4(p.pid, 0)
        p.returncode = 0
    r = dict(wrk_cpu=ru.ru_utime + ru.ru_stime, pct={})
    for line in open(path):
        f = line.split()
        if line.startswith("@@R"):
            r.update(reqs=int(f[1]), dur=int(f[2]) / 1e6, bytes=int(f[3]), errors=sum(int(x) for x in f[4:9]))
        elif line.startswith("@@P"):
            r["pct"][f[1]] = int(f[2])
        elif line.startswith("@@M"):
            r.update(mean=float(f[1]), max=int(f[2]))
    if "reqs" not in r:
        r.update(reqs=0, dur=secs, bytes=0, errors=-1)
    return r

def verify(name, pid):
    vp = SRC + ("/verify_sni.py" if TLS else "/verify.py")   # sni-plain: verify.py behind the ClientHello
    if not os.path.exists(vp):
        return "skipped (verify.py not found)"
    args = ["python3", "-I", vp, str(CFG[name]["port"])] + ([str(pid)] if CFG[name].get("ours") else [])
    env = dict(os.environ)
    if SNI and not TLS:
        env["VERIFY_HELLO"] = HELLO.hex()                   # each connection starts with it, as wrk's do
    if TLS:                       # failover checks: flip the backends' /health through flag files in WORK
        env["EDGE_WORK"] = WORK
        if name.startswith("nginx"):
            env["EDGE_PASSIVE"] = "1"                       # nginx OSS: no active health checks
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=240, env=env)
        out = r.stdout.strip().splitlines()
        fails = [l for l in out if "FAIL" in l and not l.startswith("RESULT")]
        return "PASS" if r.returncode == 0 else "FAIL: " + "; ".join(x.split("  ")[0] + " " + x.split("FAIL")[-1].strip() for x in fails)[:300]
    except subprocess.TimeoutExpired:
        return "FAIL: verify timed out"

def mix_check(port):
    """Fetch every web-mix file once through `port` (keep-alive) and compare it with the file on disk."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        if TLS:
            s = TLS_CTX.wrap_socket(s, server_hostname=HOST)
        buf = b""
        for path, size in MIX:
            s.sendall(HELLO + f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
            while b"\r\n\r\n" not in buf:
                d = s.recv(65536)
                if not d:
                    return f"FAIL: eof before headers of {path}"
                buf += d
            hdr, buf = buf.split(b"\r\n\r\n", 1)
            if not hdr.startswith(b"HTTP/1.1 200"):
                return f"FAIL: {path}: {hdr[:30]!r}"
            cl = int([l for l in hdr.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
            while len(buf) < cl:
                d = s.recv(1 << 20)
                if not d:
                    return f"FAIL: eof in body of {path}"
                buf += d
            if buf[:cl] != pattern(size):
                return f"FAIL: {path}: body differs ({cl} bytes, want {size})"
            buf = buf[cl:]
        s.close()
        return "PASS"
    except OSError as e:
        return f"FAIL: {e}"

# ----------------------------------------------------------- host tuning ----
TUNED, DMA_FD = [], None
def tune_apply():
    global DMA_FD
    try:
        DMA_FD = os.open("/dev/cpu_dma_latency", os.O_WRONLY)       # holds while the fd is open
        os.write(DMA_FD, (20).to_bytes(4, "little"))
        NOTES.append("TUNE: /dev/cpu_dma_latency = 20 us (deep C-states off, C1 allowed)")
    except OSError as e:
        NOTES.append(f"TUNE: /dev/cpu_dma_latency not set ({e})")
    # The widened range covers the bench's own fixed ports, and at thousands of new connections/s an
    # ephemeral port soon lands on one, so a proxy could not bind its listener (seen: nginx on 18444).
    # Reserve them first.
    try:
        rp = "/proc/sys/net/ipv4/ip_local_reserved_ports"
        old = open(rp).read().strip()
        with open(rp, "w") as f:
            f.write(f"{old},18080-18447" if old else "18080-18447")
        TUNED.append((rp, old))
    except OSError as e:
        NOTES.append(f"TUNE: could not reserve ports 18080-18447 ({e}); port range left alone")
        return
    for key, val in (("net/ipv4/ip_local_port_range", "1024\t65535"),):
        p = "/proc/sys/" + key
        try:
            old = open(p).read().strip()
            with open(p, "w") as f:
                f.write(val)
            TUNED.append((p, old))
            NOTES.append(f"TUNE: {key.replace('/', '.')} = {val.split()[0]}-{val.split()[1]} (was {' '.join(old.split())})")
        except OSError as e:
            NOTES.append(f"TUNE: {key} not set ({e})")

def tfo_apply():
    p = "/proc/sys/net/ipv4/tcp_fastopen"
    if TFO:
        NOTES.append("TFO=1: proxy -> backend TCP Fast Open for proxy.c (-F) and HAProxy (server 'tfo'); "
                     "nginx's stream module has no TFO towards upstreams, so nginx runs without it")
    try:
        old = int(open(p).read())
    except OSError as e:
        NOTES.append(f"TFO: cannot read {p} ({e})"); return
    if old & 3 == 3:
        NOTES.append(f"TFO: net.ipv4.tcp_fastopen = {old} already allows client and server TFO"); return
    try:
        with open(p, "w") as f:
            f.write(str(old | 3))
        TUNED.append((p, str(old)))
        NOTES.append(f"TFO: net.ipv4.tcp_fastopen = {old | 3} (was {old})")
    except OSError as e:
        NOTES.append(f"TFO: net.ipv4.tcp_fastopen is {old} and could not be set ({e}): without the server bit (2) "
                     "backends ignore SYN data, so TFO has no effect in this run")

def tune_revert():
    for p, old in reversed(TUNED):
        try:
            with open(p, "w") as f:
                f.write(old)
        except OSError:
            pass
    if DMA_FD is not None:
        os.close(DMA_FD)

def mitigations_on():
    try:
        return [n for n in os.listdir("/sys/devices/system/cpu/vulnerabilities")
                if open(f"/sys/devices/system/cpu/vulnerabilities/{n}").read().startswith("Mitigation")]
    except OSError:
        return []

def profile(name, size, conns, close):
    """perf record the proxy cores while wrk runs; returns (label, top symbol lines)."""
    c = CFG[name]
    label = f"{name} {size}B c={conns}{' new-conn' if close else ''}"
    p = start(name, f"profile:{size}:{conns}:{int(close)}")
    procs.append(p)
    run_wrk(c["port"], size, conns, 1, close)
    data = f"{WORK}/perf.data"
    th = threading.Thread(target=run_wrk, args=(c["port"], size, conns, SECS, close)); th.start()
    time.sleep(1)
    subprocess.run([PERF_BIN, "record", "-C", ",".join(map(str, P_CPUS)), "-o", data, "--",
                    "sleep", str(max(2, SECS - 2))], capture_output=True)
    th.join()
    stop(p, c["port"]); procs.remove(p)
    rep = subprocess.run([PERF_BIN, "report", "-i", data, "--stdio", "--sort", "dso,sym", "--percent-limit", "0.5"],
                         capture_output=True, text=True).stdout
    fn = f"profile-{name}-{size}-{conns}{'-close' if close else ''}.txt"
    open(f"{OUT}/{fn}", "w").write(rep)
    os.unlink(data)
    return label, fn, [l for l in rep.splitlines() if l.strip() and not l.startswith("#")][:30]

# ---------------------------------------------------------------- main -----
os.makedirs(OUT + "/logs", exist_ok=True)
PROFILES = []
for name in (t[3] for t in PROFILE):
    if name not in CFG or CFG[name]["argv"] is None:
        die(f"PROFILE: {name} is not a proxy config; available: {' '.join(k for k in CFG if CFG[k]['argv'])}")
if PROFILE and not (PERF_BIN and PINNED):
    die("PROFILE needs perf and a pinned layout (proxy cores to sample)")
mit = mitigations_on()
if mit:
    NOTES.append(f"{len(mit)} CPU vulnerability mitigations active ({', '.join(mit)}): syscalls and kernel entry "
                 "cost more; 'mitigations=off' on the kernel command line (reboot, less secure) helps every proxy, "
                 "most those making the most syscalls")
if DEFER:
    NOTES.append("DEFER=1: TCP_DEFER_ACCEPT on every proxy listener (proxy.c -A, nginx deferred, HAProxy defer-accept)")
if TUNE:
    tune_apply()
if TRICKS and "uring_tricks" in ORDER:
    NOTES.append(f"uring_tricks: proxy.c with {' '.join(TRICKS)} (opt-in TCP tricks; TRICKS=0 drops the line)"
                 + ("; haproxy_tfo is HAProxy with 'server ... tfo', its equivalent (nginx's stream module has "
                    "no TFO towards upstreams)" if TRICKS_TFO else ""))
if TFO or (TRICKS_TFO and {"uring_tricks", "haproxy_tfo"} & set(ORDER)):
    tfo_apply()
for port in (BPORT, UPORT, NPORT, HPORT) + ((BPORT_B,) if SNI else ()):
    if port_open(port):
        die(f"port {port} already in use")

backend = subprocess.Popen(BACKEND_ARGV, stdout=open(OUT + "/logs/backend.log", "w"),
                           stderr=subprocess.STDOUT, preexec_fn=aff(B_CPUS))
procs = [backend]
try:
    for _ in range(100):
        if http_ok(TARGET):
            break
        time.sleep(0.05)
    else:
        die("backend did not start")

    meta = dict(suite=SUITE, skipped=SKIPPED,
                workers=W_RAW, workers_eff=W_EFF, nginx_workers=NGX_W, backend=BACKEND, secs=SECS, rounds=ROUNDS, warmup=WARM, sizes=SIZES, configs=ORDER,
                pinned=PINNED, p_cpus=P_CPUS, b_cpus=B_CPUS, w_cpus=W_CPUS, backend_threads=BT, wrk_threads=WT,
                cores=CORES, l2_bytes=L2, l2_pool=f"32768x{L2N}", perf=PERF_BIN, perf_events=PERF_EV,
                argv={k: CFG[k]["argv"] for k in ORDER}, notes=NOTES)
    n_runs = len(SIZES) * ROUNDS * len(ORDER)
    eta = n_runs * (SECS + WARM + 1.2) + (len(ORDER) - 1) * 8 * (VERIFY == "1")
    log(f">> layout: proxy cpus={P_CPUS} backend cpus={B_CPUS} ({BT} thr) wrk cpus={W_CPUS} ({WT} thr)"
        if PINNED else f">> no pinning (only {len(CORES)} physical cores)")
    log(f">> workers: {W_RAW} -> proxy.c {W_EFF}, nginx {NGX_W}, haproxy {'auto' if AUTO else W}; backend={BACKEND} ({BT})")
    log(f">> configs: {' '.join(ORDER)}")
    log(f">> L2/core={L2 >> 10} KiB;  perf: {'yes ' + ','.join(PERF_EV) if PERF_BIN else 'no'}")
    for n in NOTES:
        log("   note:", n)
    log(f">> {n_runs} runs, ETA ~{eta / 60:.0f} min. Leave the machine idle.")

    ver = {}
    if VERIFY == "1":
        log(">> correctness check (data integrity, ordering, half-close, slow readers; web mix through every config)")
        for name in ORDER:
            p = start(name)
            if p:
                procs.append(p)
            checks = {"mix": mix_check(CFG[name]["port"])}
            if p and BACKEND != "nginx":       # verify.py / verify_sni.py need backend.c / the TLS backends
                checks["verify"] = verify(name, p.pid)
            bad = [f"{k} {v}" for k, v in checks.items() if v != "PASS"]
            ver[name] = "FAIL: " + "; ".join(bad) if bad else "PASS"
            if bad and name.startswith("haproxy") and TLS and all("split over 2 TLS records" in b for b in bad):
                ver[name] += " (known HAProxy limit: req.ssl_sni reads only the first TLS record; HANDOFF \"Harnesses\")"
            if p:
                stop(p, CFG[name]["port"]); procs.remove(p)
            log(f"   {name:<16} {ver[name]}  ({' + '.join(checks)})")
    meta["verify"] = ver

    recs = []
    for size, conns, close in SIZES:
        for rnd in range(ROUNDS):
            order = ORDER[rnd % len(ORDER):] + ORDER[:rnd % len(ORDER)]   # rotate to cancel position bias
            for name in order:
                c = CFG[name]
                p = start(name, f"{size}:{conns}:{int(close)}:{rnd}")
                if p:
                    procs.append(p)
                if WARM > 0:
                    run_wrk(c["port"], size, conns, max(1, int(WARM)), close)
                pids = children(p.pid) if p else []
                bt0, pt0, cs0 = ticks(children(backend.pid)), ticks(pids), cpustat()
                samp = Sampler(p.pid if p else None, (P_CPUS if p else B_CPUS) or sorted(os.sched_getaffinity(0)))
                samp.start()
                perf = {}
                pth = None
                if PERF_BIN and p and SECS >= 3:
                    pdur = SECS - 2
                    def go(pids=pids, perf=perf, pdur=pdur):
                        time.sleep(1); perf_run(pids, pdur, perf)
                    pth = threading.Thread(target=go, daemon=True); pth.start()
                w = run_wrk(c["port"], size, conns, SECS, close)
                pids2 = children(p.pid) if p else []
                bt1, pt1, cs1 = ticks(children(backend.pid)), ticks(pids2), cpustat()
                samp.stop.set(); samp.join()
                if pth:
                    pth.join()
                stop(p, c["port"])
                if p:
                    procs.remove(p)
                dur, reqs = w["dur"] or SECS, w["reqs"]
                rps = reqs / dur if dur else 0
                pst = proxy_counters(name, f"{size}:{conns}:{int(close)}:{rnd}") if c.get("ours") else {}
                rec = dict(size=size, conns=conns, close=close, round=rnd, pstats=pst, config=name, rps=rps, reqs=reqs,
                           mbps=w["bytes"] / dur / 1e6, errors=w["errors"], lat=w["pct"], lat_mean=w.get("mean"),
                           lat_max=w.get("max"),
                           wrk_util=w["wrk_cpu"] / dur / max(1, min(WT, len(W_CPUS) if W_CPUS else os.cpu_count())),
                           backend_util=((bt1[0] + bt1[1] - bt0[0] - bt0[1]) / HZ) / dur / max(1, len(B_CPUS) if B_CPUS else BT),
                           maxthr=samp.maxthr, mhz=st.mean(samp.mhz) if samp.mhz else 0,
                           temp=max(samp.temp) if samp.temp else 0)
                if p and reqs:
                    rec["task_us"] = ((pt1[0] - pt0[0]) + (pt1[1] - pt0[1])) / HZ * 1e6 / reqs
                    rec["task_user_frac"] = (pt1[0] - pt0[0]) / max(1, (pt1[0] - pt0[0]) + (pt1[1] - pt0[1]))
                    if PINNED:
                        busy, usr, sysx, sirq = cpu_split(cs0, cs1, P_CPUS)
                        rec.update(core_us=busy * len(P_CPUS) * dur * 1e6 / reqs, core_busy=busy,
                                   core_usr=usr, core_sys=sysx, core_sirq=sirq)
                    if perf and PERF_BIN:
                        preq = rps * (SECS - 2)
                        rec["perf"] = {k: v / preq for k, v in perf.items()} if preq else {}
                recs.append(rec)
                log(f"   {(str(size) + 'B') if size != 'mix' else 'web-mix':>9} c={conns:<4}{'new' if close else '   '} r{rnd + 1} {name:<16} {rps:>9.0f} req/s  p99={w['pct'].get('99', 0) / 1000:7.2f}ms"
                    f"  wrk={rec['wrk_util'] * 100:3.0f}%  {rec['mhz']:.0f}MHz {rec['temp']:.0f}C" + (f"  ERR={w['errors']}" if w["errors"] else ""))
                json.dump(dict(meta=meta, runs=recs), open(OUT + "/results.json", "w"), indent=1)
                time.sleep(0.3)
    for size, conns, close, name in PROFILE:
        log(f">> profiling {name} {size}B c={conns}{' new-conn' if close else ''}")
        PROFILES.append(profile(name, size, conns, close))
finally:
    tune_revert()                             # no-op unless TUNE/TFO changed something
    for p in procs:
        try:
            kill_group(p) if p is not backend else p.terminate(); p.wait(3)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass

# -------------------------------------------------------------- report -----
def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None

def fl(v, fmt):
    return format(v, fmt) if v is not None else "-"

def lat(us):
    if us is None:
        return "-"
    return f"{us:.0f}us" if us < 1000 else f"{us / 1000:.2f}ms"

def out(s=""):
    REPORT.append(s); print(s)

out(f"proxybench report  suite={'edge (the production path: TLS passthrough, SNI routing, replicas, health checks, backup)' if TLS else 'sni-plain (the production routing without crypto at the ends: proxy-limited)' if SNI else 'tcp (INTERNAL: single backend, no TLS, no routing; for visibility, not the production path)'}")
out(f"workers={W_RAW}(eff {W_EFF}, nginx {NGX_W}) backend={BACKEND} secs={SECS} rounds={ROUNDS}  "
    + (f"pinned proxy={P_CPUS} backend={B_CPUS} wrk={W_CPUS}" if PINNED else "unpinned"))
out(f"perf: {','.join(PERF_EV) if PERF_BIN else 'not available'}   L2/core={L2 >> 10}KiB")
for n in NOTES:
    out("note: " + n)
if meta.get("verify"):
    out("correctness: " + "  ".join(f"{k}={v.split(':')[0]}" for k, v in meta["verify"].items()))
    for k, v in meta["verify"].items():
        if v.startswith("FAIL"):
            out(f"   !! {k}: {v}")

groups = {}
for r in recs:
    groups.setdefault((r["size"], r["conns"], r.get("close", False)), {}).setdefault(r["config"], []).append(r)

summary = {}
for (size, conns, close), cfgs in groups.items():
    out()
    what = (f"web mix ({len(MIX)} static files per page view: HTML/CSS/JS/fonts/images/API JSON, mean {MIX_MEAN / 1024:.0f} KB)"
            if size == "mix" else f"{size} B responses")
    out(f"=== {what}, {conns} connections" + (", NEW CONNECTION PER REQUEST" if close else "") + " " + "=" * 30)
    base = med(x["rps"] for x in cfgs.get("nginx", [])) or med(x["rps"] for x in cfgs.get("haproxy", []))
    basename = "nginx" if cfgs.get("nginx") else "haproxy"
    out(f"{'config':<16}{'req/s':>9}{'vs ' + basename:>10}{'spread':>8}{'p50':>9}{'p90':>9}{'p99':>9}{'p99.9':>9}{'err':>5}")
    for name, rs in cfgs.items():
        rps = med(x["rps"] for x in rs)
        spread = (max(x["rps"] for x in rs) - min(x["rps"] for x in rs)) / rps * 100 if rps and len(rs) > 1 else 0
        rel = f"{rps / base * 100:.0f}%" if base else "-"
        summary.setdefault(name, []).append(rps / base if base else None)
        out(f"{name:<16}{rps:>9.0f}{rel:>10}{spread:>7.0f}%"
            + "".join(f"{lat(med(x['lat'].get(p) for x in rs)):>9}" for p in ("50", "90", "99", "99.9"))
            + f"{sum(max(0, x['errors']) for x in rs):>5}")
    out()
    hdr = f"{'cpu per request':<16}{'task us':>9}{'user%':>7}"
    if PINNED:
        hdr += f"{'core us':>9}{'busy%':>7}{'sirq%':>7}"
    hdr += f"{'thr':>5}{'wrk%':>6}{'bknd%':>7}{'MHz':>6}{'C':>4}"
    if PERF_BIN:
        hdr += f"{'cycles':>9}{'IPC':>6}{'sysc':>7}{'ctxsw':>7}{'cmiss':>7}"
    out(hdr)
    flags = set(); cb_list = []
    for name, rs in cfgs.items():
        line = f"{name:<16}{fl(med(x.get('task_us') for x in rs), '.1f'):>9}"
        uf = med(x.get("task_user_frac") for x in rs)
        line += f"{fl(uf * 100 if uf is not None else None, '.0f'):>7}"
        if PINNED:
            cb = med(x.get("core_busy") for x in rs); cs = med(x.get("core_sirq") for x in rs)
            line += f"{fl(med(x.get('core_us') for x in rs), '.1f'):>9}{fl(cb * 100 if cb is not None else None, '.0f'):>7}{fl(cs * 100 if cs is not None else None, '.0f'):>7}"
        wu = med(x["wrk_util"] for x in rs); bu = med(x["backend_util"] for x in rs)
        mhz = med(x["mhz"] for x in rs); tmax = max(x["temp"] for x in rs)
        line += (f"{max(x['maxthr'] for x in rs):>5}{wu * 100:>6.0f}{bu * 100:>7.0f}"
                 f"{fl(mhz or None, '.0f'):>6}{fl(tmax or None, '.0f'):>4}")
        if PERF_BIN:
            pf = [x.get("perf") or {} for x in rs]
            cyc = med(q.get("cycles") for q in pf); ins = med(q.get("instructions") for q in pf)
            line += (f"{fl(cyc, '.0f'):>9}{fl(ins / cyc if (cyc and ins) else None, '.2f'):>6}"
                     f"{fl(med(q.get('raw_syscalls:sys_enter') for q in pf), '.1f'):>7}"
                     f"{fl(med(q.get('context-switches') for q in pf), '.2f'):>7}{fl(med(q.get('cache-misses') for q in pf), '.0f'):>7}")
        out(line)
        if wu > 0.9:
            cb_list.append(name)
        if bu > 0.9:
            flags.add(f"backend-bound: backend at {bu * 100:.0f}% during {name}")
        if any(x["errors"] for x in rs):
            flags.add(f"errors during {name}")
        rps_l = [x["rps"] for x in rs]
        if len(rs) > 1 and (max(rps_l) - min(rps_l)) / max(1, med(rps_l)) > 0.15:
            flags.add(f"noisy: {name} varied >15% between rounds")
        if PINNED:
            cb = med(x.get("core_busy") for x in rs)
            if cb is not None and cb < 0.8 and name != "direct" and wu < 0.9 and bu < 0.9:
                flags.add(f"{name}: proxy cores only {cb * 100:.0f}% busy and nothing else saturated -> latency/scheduling bound, not CPU bound")
    if cb_list:
        flags.add("client-bound (wrk >90% busy, true gaps are larger): " + ", ".join(cb_list))
    mh = [x["mhz"] for n_, rs in cfgs.items() if n_ != "direct" for x in rs if x["mhz"]]
    if mh and min(mh) < 0.85 * max(mh):
        flags.add(f"clock varied {min(mh):.0f}-{max(mh):.0f} MHz across runs (boost/thermal)")
    tp = [x["temp"] for rs in cfgs.values() for x in rs]
    if tp and max(tp) >= 90:
        flags.add(f"hot: {max(tp):.0f}C, likely thermal throttling")
    ours_rs = {n: rs for n, rs in cfgs.items() if any(x.get("pstats") for x in rs)}
    if ours_rs:
        out(f"{'proxy.c counters':<16}{'conns':>8}{'->splice':>10}{'->copy':>8}{'spills':>8}{'enobufs':>9}{'splice/req':>11}")
        for name, rs in ours_rs.items():
            def m(k):
                return med(x["pstats"].get(k, 0) for x in rs if x.get("pstats"))
            spr = med((x["pstats"].get("splices", 0) / x["reqs"]) for x in rs if x.get("pstats") and x["reqs"])
            out(f"{name:<16}{m('accepted'):>8.0f}{m('to_splice'):>10.0f}{m('to_copy'):>8.0f}{m('spills'):>8.0f}"
                f"{m('enobufs'):>9.0f}{fl(spr, '.2f'):>11}")
    for f in sorted(flags):
        out("  ! " + f)

out()
out("=== overall (geometric mean of req/s relative to nginx/haproxy across sizes) ===")
for name, v in summary.items():
    v = [x for x in v if x]
    if v:
        g = 1.0
        for x in v:
            g *= x
        out(f"  {name:<16}{g ** (1 / len(v)) * 100:6.0f}%")
for label, fn, lines in PROFILES:
    out()
    out(f"=== profile: {label}  (proxy cores; full list in {fn}) ===")
    for l in lines:
        out("  " + l.rstrip())
out()
out("legend: task us = proxy process CPU per request (whether it includes network softirq depends on the kernel's")
out("accounting); core us = whole proxy-core time per request incl. softirq (pinned only); sirq% = softirq share")
out("of proxy cores; thr = max threads")
out("(io-wq helpers show up here); wrk%/bknd% = load generator / backend utilisation; perf columns are per")
out("request on the proxy cores: cycles, IPC, syscalls, context switches, cache misses.")
open(OUT + "/report.txt", "w").write("\n".join(REPORT) + "\n")
PY

export WORK OUT SRC
rc=0
python3 "$WORK/bench.py" || rc=$?
cp "$WORK"/*.conf "$WORK"/*.cfg "$OUT/logs/" 2>/dev/null || true
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$OUT" "$OUT.tar.gz"
rm -rf "$WORK"
echo
echo ">> report:  $OUT/report.txt      (paste this back)"
echo ">> archive: $OUT.tar.gz          (sysinfo, raw json, logs)"
exit $rc
