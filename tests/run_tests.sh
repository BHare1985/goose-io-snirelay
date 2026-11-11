#!/usr/bin/env bash
# Builds every test with --debug, runs it, and prints the requirement rows it proves.
#
#   tests/run_tests.sh              all unit tests (and net tests when they exist)
#   tests/run_tests.sh sni          only tests whose file name contains "sni"
#
# REPEAT=20 tests/run_tests.sh forward   runs each matching NETWORK driver 20 times and keeps every FAIL line
# (for tests that failed once and were not understood: a flake is a bug until it is explained).
#
# GOOSE selects the compiler (default: goose-kb/bin/goose when present, else goose on PATH).
# Exit status is non-zero if any test fails to build or fails.
set -u -o pipefail
cd "$(dirname "$0")/.."
GOOSE="${GOOSE:-}"
if [ -z "$GOOSE" ]; then
    if [ -x goose-kb/bin/goose ]; then GOOSE=goose-kb/bin/goose; else GOOSE=goose; fi
fi
filter="${1:-}"
work="$(mktemp -d -t tcprouter_tests.XXXXXXXX)"
trap 'rm -rf "$work"' EXIT

failed=0; ran=0
for src in tests/unit/*_test.goose tests/net/*_test.goose; do
    [ -e "$src" ] || continue
    case "$src" in *"$filter"*) ;; *) continue ;; esac
    name="$(basename "$src" .goose)"
    rows="$(sed -n 's|^// Proves: *\([^(]*\).*|\1|p' "$src" | head -1)"
    ran=$((ran + 1))
    if ! "$GOOSE" build --debug -o "$work/$name" "$src" >"$work/$name.build.log" 2>&1; then
        echo "BUILD FAILED  $src"; sed 's/^/    /' "$work/$name.build.log" | head -20
        failed=$((failed + 1)); continue
    fi
    if "$work/$name" >"$work/$name.out" 2>&1; then
        echo "PASS  $name   rows: ${rows:-none}   $(tail -1 "$work/$name.out")"
    else
        echo "FAIL  $name   rows: ${rows:-none}   $(tail -1 "$work/$name.out")"
        grep '^FAIL' "$work/$name.out" | head -8 | sed 's/^/    /'
        failed=$((failed + 1))
    fi
done
# Network tests: build the system under test once (with --debug), then run each driver.
net_drivers=(tests/net/*_test.py)
if [ -e "${net_drivers[0]}" ]; then
    if "$GOOSE" build --debug -o "$work/forward_server" tests/net/harness/forward_server.goose >"$work/forward_server.build.log" 2>&1; then
        export FORWARD_SERVER="$work/forward_server"
        "$GOOSE" build --debug -o "$work/handler_server" tests/net/harness/handler_server.goose >"$work/handler_server.build.log" 2>&1 \
            && export HANDLER_SERVER="$work/handler_server" \
            || { echo "BUILD FAILED  tests/net/harness/handler_server.goose"; sed 's/^/    /' "$work/handler_server.build.log" | head -20; failed=$((failed + 1)); }
        "$GOOSE" build --debug -o "$work/policy_server" tests/net/harness/policy_server.goose >"$work/policy_server.build.log" 2>&1 \
            && export POLICY_SERVER="$work/policy_server" \
            || { echo "BUILD FAILED  tests/net/harness/policy_server.goose"; sed 's/^/    /' "$work/policy_server.build.log" | head -20; failed=$((failed + 1)); }
        "$GOOSE" build --debug -o "$work/policy_message_server" tests/net/harness/policy_message_server.goose >"$work/policy_message_server.build.log" 2>&1 \
            && export POLICY_MESSAGE_SERVER="$work/policy_message_server" \
            || { echo "BUILD FAILED  tests/net/harness/policy_message_server.goose"; sed 's/^/    /' "$work/policy_message_server.build.log" | head -20; failed=$((failed + 1)); }
        "$GOOSE" build --debug -o "$work/connect_ms_server" tests/net/harness/connect_ms_server.goose >"$work/connect_ms_server.build.log" 2>&1 \
            && export CONNECT_MS_SERVER="$work/connect_ms_server" \
            || { echo "BUILD FAILED  tests/net/harness/connect_ms_server.goose"; sed 's/^/    /' "$work/connect_ms_server.build.log" | head -20; failed=$((failed + 1)); }
        # test-only fast echo backend (C, independent of tcprouter): generation_test needs 100,000 accepts/s
        ${CC:-cc} -O1 -o "$work/echo_server" tests/net/harness/echo_server.c && export ECHO_SERVER="$work/echo_server"
        for drv in "${net_drivers[@]}"; do
            name="$(basename "$drv" .py)"
            case "$drv" in *"$filter"*) ;; *) continue ;; esac
            rows="$(sed -n 's|^# Proves: *\([^(]*\).*|\1|p' "$drv" | head -1)"
            ran=$((ran + 1))
            bad=0
            for round in $(seq 1 "${REPEAT:-1}"); do
                if ! timeout 600 python3 "$drv" >"$work/$name.out" 2>&1; then
                    bad=$((bad + 1))
                    echo "FAIL  $name (run $round)   rows: ${rows:-none}   $(tail -1 "$work/$name.out")"
                    grep -E '^(FAIL|SKIP)' "$work/$name.out" | head -8 | sed 's/^/    /'
                    cp "$work/$name.out" "/tmp/tcprouter-$name-fail-$round.out"
                fi
            done
            if [ "$bad" -eq 0 ]; then
                echo "PASS  $name   rows: ${rows:-none}   $(tail -1 "$work/$name.out")${REPEAT:+   ($REPEAT runs)}"
            else
                failed=$((failed + 1))
            fi
        done
    else
        echo "BUILD FAILED  tests/net/harness/forward_server.goose"; sed 's/^/    /' "$work/forward_server.build.log" | head -20
        failed=$((failed + 1))
    fi
fi
echo "$ran test file(s) run, $failed failed"
[ "$failed" -eq 0 ]
