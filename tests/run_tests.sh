#!/usr/bin/env bash
# Builds every test with --debug, runs it, and prints the requirement rows it proves.
#
#   tests/run_tests.sh              all unit tests (and net tests when they exist)
#   tests/run_tests.sh sni          only tests whose file name contains "sni"
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
echo "$ran test file(s) run, $failed failed"
[ "$failed" -eq 0 ]
