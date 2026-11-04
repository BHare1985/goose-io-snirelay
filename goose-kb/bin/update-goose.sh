#!/usr/bin/env bash
# Brings the Goose compiler used by this project to the latest upstream master and rebuilds it.
# Run it at the start of every session and before a milestone; then re-run tests/run_tests.sh.
#   goose-kb/bin/update-goose.sh          fetch, fast-forward, rebuild (about 10 minutes when src/ changed)
#   goose-kb/bin/update-goose.sh --check  only say whether upstream is ahead
set -eu -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/upstream/goose"
BUILD="$HERE/upstream/build"
git -C "$SRC" fetch -q origin
local_rev="$(git -C "$SRC" rev-parse --short HEAD)"
remote_rev="$(git -C "$SRC" rev-parse --short origin/master)"
if [ "$local_rev" = "$remote_rev" ]; then echo "goose is current: $local_rev"; exit 0; fi
echo "upstream is ahead: $local_rev -> $remote_rev ($(git -C "$SRC" rev-list --count HEAD..origin/master) commits)"
[ "${1:-}" = "--check" ] && exit 1
git -C "$SRC" merge -q --ff-only origin/master
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" -j"$(nproc)"
"$BUILD/goose" version
