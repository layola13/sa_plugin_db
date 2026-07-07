#!/usr/bin/env bash
set -euo pipefail

build_path="${1:-build.zig}"

if [[ -z "$build_path" || ! -f "$build_path" ]]; then
    echo "build.zig is required for SQLite archive rewrite checks" >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

rewrite_script="$tmp_dir/sqlite_archive_rewrite.sh"
python3 - "$build_path" "$rewrite_script" <<'PY'
import sys
from pathlib import Path

build_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
lines = build_path.read_text().splitlines()

in_fn = False
script_lines = []
for line in lines:
    if line.startswith("fn addSqliteStdArchiveStep("):
        in_fn = True
        continue
    if not in_fn:
        continue
    if '"sqlite-std-archive"' in line:
        break
    stripped = line.lstrip()
    if stripped.startswith("\\\\"):
        script_lines.append(stripped[2:])

script = "\n".join(script_lines).strip() + "\n"
required = [
    "set -euo pipefail",
    "mktemp -d",
    "trap 'rm -rf \"$work\"' EXIT",
    "objs=(\"$work\"/*.o)",
    "sqlite std archive rewrite found no object files",
    "--redefine-sym sqlite3_prepare=sa_std_stub_sqlite3_prepare",
    "--redefine-sym sqlite3_step=sa_std_stub_sqlite3_step",
    "--redefine-sym sqlite3_finalize=sa_std_stub_sqlite3_finalize",
]
missing = [needle for needle in required if needle not in script]
if missing:
    raise SystemExit("extracted SQLite archive rewrite script is missing: " + ", ".join(missing))
out_path.write_text(script)
PY

empty_archive="$tmp_dir/empty.a"
ar rcs "$empty_archive"
empty_out_dir="$tmp_dir/empty-out"
empty_out="$empty_out_dir/libempty-rewritten.a"
mkdir -p "$empty_out_dir"

if bash "$rewrite_script" "$empty_archive" "$empty_out" >"$tmp_dir/empty.stdout" 2>"$tmp_dir/empty.stderr"; then
    echo "SQLite archive rewrite unexpectedly accepted an empty archive" >&2
    exit 1
fi
if ! grep -F "sqlite std archive rewrite found no object files" "$tmp_dir/empty.stderr" >/dev/null; then
    echo "SQLite archive rewrite empty-archive failure did not report the expected diagnostic" >&2
    cat "$tmp_dir/empty.stderr" >&2
    exit 1
fi
if compgen -G "$empty_out_dir/sqlite_link_std_work.*" >/dev/null; then
    echo "SQLite archive rewrite left a work directory after empty-archive failure" >&2
    exit 1
fi

cat >"$tmp_dir/sqlite_stub.c" <<'C'
int sqlite3_prepare(void) { return 0; }
int sqlite3_step(void) { return 0; }
int sqlite3_finalize(void) { return 0; }
C
zig cc -c "$tmp_dir/sqlite_stub.c" -o "$tmp_dir/sqlite_stub.o"
stub_archive="$tmp_dir/libstub.a"
ar rcs "$stub_archive" "$tmp_dir/sqlite_stub.o"
ok_out_dir="$tmp_dir/ok-out"
ok_out="$ok_out_dir/libstub-rewritten.a"
mkdir -p "$ok_out_dir"

bash "$rewrite_script" "$stub_archive" "$ok_out"
if compgen -G "$ok_out_dir/sqlite_link_std_work.*" >/dev/null; then
    echo "SQLite archive rewrite left a work directory after success" >&2
    exit 1
fi

nm -g "$ok_out" >"$tmp_dir/rewritten.nm"
for symbol in \
    sa_std_stub_sqlite3_prepare \
    sa_std_stub_sqlite3_step \
    sa_std_stub_sqlite3_finalize
do
    if ! grep -E "[[:space:]]$symbol$" "$tmp_dir/rewritten.nm" >/dev/null; then
        echo "SQLite archive rewrite did not produce renamed symbol: $symbol" >&2
        cat "$tmp_dir/rewritten.nm" >&2
        exit 1
    fi
done
for symbol in sqlite3_prepare sqlite3_step sqlite3_finalize; do
    if grep -E "[[:space:]]$symbol$" "$tmp_dir/rewritten.nm" >/dev/null; then
        echo "SQLite archive rewrite kept original symbol: $symbol" >&2
        cat "$tmp_dir/rewritten.nm" >&2
        exit 1
    fi
done

echo "SQLite archive rewrite guard passed: empty archive fails cleanly, work dirs are cleaned, and sqlite stub symbols are renamed"
