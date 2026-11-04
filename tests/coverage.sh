#!/usr/bin/env bash
# Prints the requirement rows (design/05-requirements.md) that no test file lists in its "Proves:" line.
cd "$(dirname "$0")/.."
proved="$(grep -h '^// Proves:' tests/unit/*.goose tests/net/*.goose 2>/dev/null | grep -o '[A-Z][A-Z]-[0-9]*[a-z]*' | sort -u)"
grep -o '^| [A-Z][A-Z]-[0-9]*[a-z]* ' design/05-requirements.md | tr -d '| ' | sort -u | while read -r row; do
    echo "$proved" | grep -qx "$row" || echo "$row"
done
