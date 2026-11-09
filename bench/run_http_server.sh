#!/usr/bin/env bash
# examples/http_server against the C backend with wrk, same rows as RESULTS.md. Takes the host lock.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"; OUT="$HERE/results/http-server-$STAMP"; mkdir -p "$OUT"
"$ROOT/goose-kb/bin/goose" build -o "$HERE/http_server" "$ROOT/examples/http_server.goose"
cc -O2 -o "$HERE/backend" "$HERE/backend.c" -lpthread
uptime > "$OUT/uptime-before.txt"
"$HOME/dev/docker/tools/run-locked.sh" python3 "$HERE/http_server_bench.py" 2>&1 | tee "$OUT/table.md"
echo "results: $OUT"
