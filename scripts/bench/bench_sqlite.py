#!/usr/bin/env python3
"""SQLite reference bench for the sa_plugin_db concurrency report.

Same dataset as the Zig bench: table t(id INTEGER, val INTEGER)
with 20,000 rows, val = 1 (sum = 20,000), plus a 2,000-row twin
for the write scenario. Access path: python3 sqlite3 module ->
libsqlite3 in-process library call, file-backed database.
Each scenario runs 3 rounds; the printed line is the median round.
Output CSV matches bench_main.zig:
  scenario,threads,ops,wall_ms,ops_per_sec,p50_us,p99_us,bad
"""
import os
import sqlite3
import statistics
import sys
import threading
import time

ROWS = 20_000
WRITE_ROWS = 2_000
ROUNDS = 3


def percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0
    idx = min(len(sorted_vals) - 1, (len(sorted_vals) * pct) // 100)
    return sorted_vals[idx]


def report(scenario, threads, ops, wall_ns, latencies_ns, bad):
    latencies_ns.sort()
    wall_ms = wall_ns / 1e6
    tput = ops / (wall_ms / 1000.0) if wall_ms > 0 else 0.0
    p50 = percentile(latencies_ns, 50) // 1000
    p99 = percentile(latencies_ns, 99) // 1000
    print(f"{scenario},{threads},{ops},{wall_ms:.1f},{tput:.1f},{p50},{p99},{bad}", flush=True)


def timed(fn):
    start = time.perf_counter_ns()
    result = fn()
    return result, time.perf_counter_ns() - start


def build(db_path):
    if os.path.exists(db_path):
        os.unlink(db_path)
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, val INTEGER)")
    conn.executemany("INSERT INTO t VALUES (?, 1)", [(i,) for i in range(ROWS)])
    conn.execute("CREATE TABLE w (id INTEGER PRIMARY KEY, val INTEGER)")
    conn.executemany("INSERT INTO w VALUES (?, 1)", [(i,) for i in range(WRITE_ROWS)])
    conn.commit()
    conn.close()


def run_point(db_path, threads, ops):
    latencies = []
    results = []
    def worker():
        conn = sqlite3.connect(db_path)
        per = ops // threads
        for _ in range(per):
            value, elapsed = timed(lambda: conn.execute("SELECT val FROM t WHERE id = 12345").fetchone())
            latencies.append(elapsed)
            results.append(value[0])
        conn.close()
    start = time.perf_counter_ns()
    pool = [threading.Thread(target=worker) for _ in range(threads)]
    for t in pool: t.start()
    for t in pool: t.join()
    wall = time.perf_counter_ns() - start
    report("point", threads, len(latencies), wall, latencies, sum(1 for v in results if v != 1))

def run_readsum(db_path, threads, ops):
    latencies = []
    results = []
    def worker():
        conn = sqlite3.connect(db_path)
        per = ops // threads
        for _ in range(per):
            value, elapsed = timed(lambda: conn.execute("SELECT sum(val) FROM t").fetchone())
            latencies.append(elapsed)
            results.append(value[0])
        conn.close()
    start = time.perf_counter_ns()
    pool = [threading.Thread(target=worker) for _ in range(threads)]
    for t in pool: t.start()
    for t in pool: t.join()
    wall = time.perf_counter_ns() - start
    report("readsum", threads, len(latencies), wall, latencies, sum(1 for v in results if v != ROWS))


def run_write(db_path, commits):
    conn = sqlite3.connect(db_path)
    latencies = []
    start = time.perf_counter_ns()
    for i in range(commits):
        value = 1 if i % 2 == 0 else 2
        _, elapsed = timed(lambda: (conn.execute("UPDATE w SET val = ?", (value,)), conn.commit()))
        latencies.append(elapsed)
    wall = time.perf_counter_ns() - start
    conn.close()
    report("write", 1, len(latencies), wall, latencies, 0)


def median_line(scenario, threads, fn):
    """Run one scenario ROUNDS times and print the median-tput line."""
    import io
    import contextlib
    lines = []
    for _ in range(ROUNDS):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            fn()
        lines.append(buf.getvalue().strip())
    parsed = []
    for line in lines:
        parts = line.split(",")
        parsed.append((float(parts[4]), line))
    parsed.sort(key=lambda item: item[0])
    print(parsed[len(parsed) // 2][1], flush=True)


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dbconc-bench/sqlite.db"
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    build(db_path)
    for threads in (1, 2, 4, 8, 16, 32):
        median_line("readsum", threads, lambda t=threads: run_readsum(db_path, t, 480))
    for threads in (1, 4, 8):
        median_line("point", threads, lambda t=threads: run_point(db_path, t, 1920))
    median_line("write", 1, lambda: run_write(db_path, 60))


if __name__ == "__main__":
    main()
