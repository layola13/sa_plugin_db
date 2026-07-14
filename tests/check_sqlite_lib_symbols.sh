#!/usr/bin/env bash
set -euo pipefail

sqlite_lib="${1:-/usr/lib/x86_64-linux-gnu/libsqlite3.so.0}"
shift || true

if [[ -z "$sqlite_lib" || ! -f "$sqlite_lib" ]]; then
    echo "SQLite shared library is missing: $sqlite_lib" >&2
    exit 1
fi

if (( $# == 0 )); then
    set -- benchmark_test/sqlite_*.sa
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$tmp_dir/required.txt" "$@" <<'PY'
import re
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
sources = [Path(arg) for arg in sys.argv[2:]]
if not sources:
    raise SystemExit("no SQLite benchmark sources were provided")

missing = [str(path) for path in sources if not path.is_file()]
if missing:
    raise SystemExit("missing SQLite benchmark source(s): " + ", ".join(missing))

symbols = set()
for path in sources:
    for match in re.finditer(r"@extern\s+(sqlite3_[A-Za-z0-9_]+)\s*\(", path.read_text()):
        symbols.add(match.group(1))

if not symbols:
    raise SystemExit("no sqlite3 extern declarations found in SQLite benchmark sources")

out_path.write_text("\n".join(sorted(symbols)) + "\n")
PY

nm -D --defined-only "$sqlite_lib" >"$tmp_dir/sqlite.nm"
awk '{print $NF}' "$tmp_dir/sqlite.nm" | sed 's/@@.*//; s/@.*//' | sort -u >"$tmp_dir/exported.txt"

if ! missing=$(comm -23 "$tmp_dir/required.txt" "$tmp_dir/exported.txt"); then
    echo "failed to compare SQLite required/exported symbols" >&2
    exit 1
fi

if [[ -n "$missing" ]]; then
    echo "SQLite shared library is missing required benchmark symbol(s):" >&2
    printf '%s\n' "$missing" >&2
    echo "library: $sqlite_lib" >&2
    exit 1
fi

required_count=$(wc -l <"$tmp_dir/required.txt" | tr -d ' ')
echo "SQLite lib symbol guard passed: required=$required_count library=$sqlite_lib"
