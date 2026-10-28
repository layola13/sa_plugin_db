#!/bin/bash
# Concurrency capacity bench: our db curve + SQLite reference.
# PostgreSQL reference lives in bench_pg.sh (needs a server).
# Usage: run_bench.sh <worktree> <sci-src-dir> <out-dir>
set -u
WT="${1:?worktree path}"
SCI_SRC="${2:?sci src dir}"
OUT="${3:?output dir}"
mkdir -p "$OUT"
BENCH_DIR="$OUT/run"
rm -rf "$BENCH_DIR"
mkdir -p "$BENCH_DIR"

{
  echo "# machine"
  echo "hostname=$(hostname)"
  echo "nproc=$(nproc)"
  grep -m1 "model name" /proc/cpuinfo || true
  grep -m1 "MemTotal" /proc/meminfo || true
  echo "date=$(date -Is)"
} > "$OUT/machine.txt"

cd "$WT" || exit 1
zig build-exe --dep sio --dep plugin_api \
  -Mroot=bench_root.zig -O ReleaseFast \
  -Msio="$SCI_SRC/sa_io.zig" -Mplugin_api=src/plugin_api.zig \
  -femit-bin="$BENCH_DIR/bench" || exit 1

cd "$BENCH_DIR" || exit 1
./bench setup || exit 1

OURS="$OUT/results_ours.csv"
: > "$OURS"
for round in 1 2 3; do
  for threads in 1 2 4 8 16 32; do
    ./bench readsum "$threads" 480 >> "$OURS" 2>&1
  done
  for threads in 1 4 8; do
    ./bench point "$threads" 480 >> "$OURS" 2>&1
  done
  ./bench write 1 60 >> "$OURS" 2>&1
  ./bench mixed 4 25 >> "$OURS" 2>&1
done

python3 "$WT/scripts/bench/bench_sqlite.py" "$BENCH_DIR/sqlite.db" > "$OUT/results_sqlite.csv" 2>&1

echo "BENCH_DONE $OUT"
