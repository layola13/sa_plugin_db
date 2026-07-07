#!/usr/bin/env bash
set -euo pipefail

build_path="${1:-build.zig}"

if [[ -z "$build_path" || ! -f "$build_path" ]]; then
    echo "build.zig is required for benchmark parser guard checks" >&2
    exit 1
fi

require_count_at_least() {
    local needle="$1"
    local minimum="$2"
    local count
    count=$(grep -F -- "$needle" "$build_path" | wc -l | tr -d ' ')
    if (( count < minimum )); then
        echo "missing benchmark parser guard in $build_path: $needle (found $count, expected at least $minimum)" >&2
        exit 1
    fi
}

require_text() {
    local needle="$1"
    if ! grep -F -- "$needle" "$build_path" >/dev/null; then
        echo "missing benchmark parser guard in $build_path: $needle" >&2
        exit 1
    fi
}

forbid_text() {
    local needle="$1"
    if grep -F -- "$needle" "$build_path" >/dev/null; then
        echo "forbidden benchmark parser guard text in $build_path: $needle" >&2
        exit 1
    fi
}

require_text 'b.step("check-benchmark-parser-guards"'
require_text "tests/check_benchmark_parser_guards.sh"
require_text "test_step.dependOn(benchmark_parser_guards_step)"

require_count_at_least 'raise SystemExit(f"benchmark output duplicate metric: {key}")' 2
require_count_at_least 'raise SystemExit(f"benchmark output invalid integer metric: {key}={raw}")' 2
require_count_at_least 'raise SystemExit(f"benchmark output negative metric: {key}={values[key]}")' 2
require_count_at_least 'if runs <= 0 or runs % 2 == 0:' 2
require_count_at_least 'raise SystemExit("benchmark compare run count must be positive odd")' 2
require_count_at_least 'Positive odd number of runs' 2
require_text 'fn requirePositiveOddRunCount(name: []const u8, value: u32) void'
require_text 'std.log.err("{s} must be a positive odd run count, got {d}"'
require_text 'std.process.exit(1)'
require_text 'requirePositiveOddRunCount("bench-compare-runs", bench_compare_runs)'
require_text 'requirePositiveOddRunCount("bench-compare-proof-runs", bench_compare_proof_runs)'
require_count_at_least 'def observed_median(values):' 2
require_count_at_least 'return sorted(values)[len(values) // 2]' 2
forbid_text 'statistics.median'
require_text 'if strict_chain_s not in ("0", "1"):'
require_text 'raise SystemExit("benchmark compare strict-chain flag must be 0 or 1")'
require_text 'if strict_insert_s not in ("0", "1"):'
require_text 'raise SystemExit("benchmark compare strict-insert flag must be 0 or 1")'
require_count_at_least 'def require_positive_keys(samples, keys, label):' 2
require_count_at_least 'non-positive timing metrics' 2
require_text 'def require_bool_keys(samples, keys, label):'
require_text 'non-boolean status metrics'
require_text 'def require_insert_consistency(samples, ok_key, rows_key, expected_rows, label):'
require_text 'rows exceed expected insert count'
require_text 'reports ok=1 but incomplete rows'
require_text 'reports ok=0 but full rows'
require_text 'missing metrics'
require_text 'f"{db_prefix}_tx_append_ns"'
require_text 'f"{db_prefix}_coltx_append_ns"'
require_text 'f"{sqlite_prefix}_append_ns"'
require_text '"db_concurrent_insert_ok"'
require_text '"db_concurrent_insert_rows"'
require_text '"sqlite_concurrent_insert_ok"'
require_text '"sqlite_concurrent_insert_rows"'
require_text '"db_serial_query_ns", "db_concurrent_query_ns", "db_concurrent_insert_ns"'
require_text '"sqlite_serial_query_ns", "sqlite_concurrent_query_ns", "sqlite_concurrent_insert_ns"'
require_text '"db_serial_query_ok", "db_concurrent_query_ok", "db_concurrent_insert_ok"'
require_text '"sqlite_serial_query_ok", "sqlite_concurrent_query_ok", "sqlite_concurrent_insert_ok"'
require_text 'print_check("raw serial query", raw_serial, sqlite_serial)'
require_text 'print_check("coltx serial query", coltx_serial, sqlite_serial)'
require_text 'print_check("raw concurrent query", raw_query, sqlite_query)'
require_text 'print_check("coltx concurrent query", coltx_query, sqlite_query)'
forbid_text 'print_check("best serial query"'
forbid_text 'print_check("best concurrent query"'
require_text 'require_insert_consistency(raw_samples, "db_concurrent_insert_ok", "db_concurrent_insert_rows", 50000, "raw db")'
require_text 'require_insert_consistency(coltx_samples, "db_concurrent_insert_ok", "db_concurrent_insert_rows", 50000, "coltx db")'
require_text 'require_insert_consistency(sqlite_samples, "sqlite_concurrent_insert_ok", "sqlite_concurrent_insert_rows", 50000, "sqlite")'

echo "benchmark parser guard passed: observed-median, positive-odd-run-count, strict-flag, missing, invalid-integer, negative, duplicate, non-positive timing, boolean status, per-path query gates, and insert row consistency checks are wired"
