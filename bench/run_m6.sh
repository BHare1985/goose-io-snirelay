#!/usr/bin/env bash
# M6: the Goose forwarder (tcprouter's forward_server) against the C proxy's epoll engine, with Steve's method (proxybench.sh,
# SUITE=tcp, run as the user: no sudo, no perf, TUNE=0). Both proxies run under the same conditions on the same host.
#
#   bench/run_m6.sh [QUICK]      run under the host lock; results go to bench/results/<timestamp>/
#
# DO NOT RUN while the Gatekeeper testbed (Danya's) or Demo 2 (Charlie/Steve) is up: ask Charlie. The run is wrapped in
# ~/dev/docker/tools/run-locked.sh, which takes results/host.lock.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/results/$STAMP"
mkdir -p "$OUT"
WORKERS="${WORKERS:-1}"

# the Goose proxy, built the way the tests build it plus an optimised build for the benchmark (not --debug)
"$ROOT/goose-kb/bin/goose" build -o "$HERE/forward_server" "$ROOT/tests/net/harness/forward_server.goose"
"$ROOT/goose-kb/bin/goose" version > "$OUT/goose-version.txt"
cc --version | head -1 > "$OUT/cc-version.txt"
( cd "$ROOT" && git rev-parse HEAD ) > "$OUT/tcprouter-commit.txt"
uptime > "$OUT/uptime-before.txt"; docker ps > "$OUT/docker-ps-before.txt" 2>&1 || true
lscpu > "$OUT/lscpu.txt"

cd "$HERE"
export NOROOT=1 SUITE=tcp WORKERS PIN=auto PERF=0 TUNE=0 TRICKS=0 VERIFY=1 SECS=8 ROUNDS=3 WARMUP=1
[ "${1:-}" = "QUICK" ] && export QUICK=1
export CUSTOM="epoll_copy:--io epoll -m copy -v"
export CONFIGS="direct epoll_copy epoll_hybrid goose"
export EXTRA="goose|1|18447|$HERE/forward_server --listen 127.0.0.1:{L} --to 127.0.0.1:{B} --workers $WORKERS --stat-ms 3600000"
"$HOME/dev/docker/tools/run-locked.sh" "$HERE/proxybench.sh" 2>&1 | tee "$OUT/proxybench.out"
uptime > "$OUT/uptime-after.txt"; docker ps > "$OUT/docker-ps-after.txt" 2>&1 || true
# keep the harness's own result folder with the raw data next to ours
for d in proxybench-*; do [ -d "$d" ] && mv "$d" "$OUT/" ; done
echo "results: $OUT"
