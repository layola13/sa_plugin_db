#!/usr/bin/env bash
set -euo pipefail

tasks_path="${1:-tasks.md}"
progress_path="${2:-progress.md}"
build_path="${3:-build.zig}"
results_path="${4:-benchmark_test/RESULTS.md}"

require_file() {
    local path="$1"
    if [[ ! -s "$path" ]]; then
        echo "required docs file is missing or empty: $path" >&2
        exit 1
    fi
}

require_text() {
    local path="$1"
    local needle="$2"
    if ! grep -F -- "$needle" "$path" >/dev/null; then
        echo "missing required docs text in $path: $needle" >&2
        exit 1
    fi
}

require_file "$tasks_path"
require_file "$progress_path"
require_file "$results_path"

if [[ -z "$build_path" || ! -f "$build_path" ]]; then
    echo "build.zig is required for dynamic docs target checks" >&2
    exit 1
fi

mapfile -t required_targets < <(
    sed -nE 's/.*b\.step\("([^"]+)".*/\1/p' "$build_path" |
        awk '/^sqlite-/ || /^bench-compare/ || /^check-benchmark/ || /^check-sqlite/ || $0 == "check-docs" || $0 == "check-proof-wiring" || $0 == "check-bounded-locks" { print }' |
        sort -u
)

if [[ "${#required_targets[@]}" -eq 0 ]]; then
    echo "no docs-relevant build targets found in $build_path" >&2
    exit 1
fi

for target in "${required_targets[@]}"; do
    require_text "$tasks_path" "$target"
    require_text "$progress_path" "$target"
done

for path in "$tasks_path" "$progress_path"; do
    require_text "$path" "disk combined append"
    require_text "$path" "report-only"
    require_text "$path" "strict-chain"
    require_text "$path" "SQLite parity"
done

require_text "$results_path" "bench-compare-proof"
require_text "$results_path" "configured-run"
require_text "$results_path" "default 7"
require_text "$results_path" "runs=N"
require_text "$results_path" "正奇数"
require_text "$results_path" "report-only"
require_text "$results_path" "strict-chain"
require_text "$results_path" "SQLite parity"
require_text "$results_path" "不能替代 SQL/ACID/WAL/crash recovery"
require_text "$results_path" "raw serial query"
require_text "$results_path" "coltx serial query"
require_text "$results_path" "raw concurrent query"
require_text "$results_path" "coltx concurrent query"
require_text "$results_path" "不能由单条更快路径掩盖另一条路径的回退"

if grep -F -- "固定运行 7 轮" "$results_path" >/dev/null; then
    echo "benchmark results docs must not describe proof targets as fixed 7-run only: $results_path" >&2
    exit 1
fi

if grep -F -- "best serial query" "$results_path" >/dev/null || grep -F -- "best concurrent query" "$results_path" >/dev/null; then
    echo "benchmark results docs must not describe concurrent query gates as best-path summaries: $results_path" >&2
    exit 1
fi

require_text "$tasks_path" "not a claim of full SQLite parity"
require_text "$progress_path" "not proof of full SQLite parity"
require_text "$tasks_path" "benchmark executable builds"
require_text "$progress_path" "benchmark executable builds"
require_text "$tasks_path" "benchmark parser guards"
require_text "$progress_path" "benchmark parser guards"
require_text "$tasks_path" "positive odd"
require_text "$progress_path" "positive odd"
require_text "$tasks_path" "proof wiring"
require_text "$progress_path" "proof wiring"
require_text "$tasks_path" "SQLite archive rewrite guard"
require_text "$progress_path" "SQLite archive rewrite guard"
require_text "$tasks_path" "bounded lock guard"
require_text "$progress_path" "bounded lock guard"

require_text "$build_path" 'b.step("check-docs"'
require_text "$build_path" "tests/check_docs.sh"
require_text "$build_path" "test_step.dependOn(check_docs_step)"
require_text "$build_path" "docs guard"
require_text "$build_path" 'b.step("check-bounded-locks"'
require_text "$build_path" "tests/check_bounded_locks.sh"
require_text "$build_path" "test_step.dependOn(bounded_locks_step)"
require_text "$build_path" "bounded lock guard"
require_text "$build_path" 'b.step("check-sqlite-archive-rewrite"'
require_text "$build_path" "tests/check_sqlite_archive_rewrite.sh"
require_text "$build_path" "test_step.dependOn(sqlite_archive_rewrite_step)"
require_text "$build_path" "SQLite archive rewrite guard"
require_text "$build_path" 'b.step("check-benchmark-parser-guards"'
require_text "$build_path" "tests/check_benchmark_parser_guards.sh"
require_text "$build_path" "test_step.dependOn(benchmark_parser_guards_step)"
require_text "$build_path" "benchmark parser guards"
require_text "$build_path" "Positive odd number of runs"
require_text "$build_path" "benchmark executable builds"
require_text "$build_path" "sqlite_audit_summary.step.dependOn(bench_step)"
require_text "$build_path" "sqlite-proof passed: sqlite-audit plus runs={d} disk/memory/concurrent performance proof completed"
require_text "$build_path" "disk combined append remains report-only unless strict-chain is explicitly requested"
require_text "$build_path" "sqlite-proof-strict-chain passed: sqlite-audit plus runs={d} strict disk/memory combined append proof and strict concurrent insert completed"
require_text "$build_path" "bench-compare passed: runs={d} disk indexed ERP, memory indexed ERP, concurrent compare, and protected artifact guard completed"
require_text "$build_path" "bench-compare-disk passed: runs={d} disk indexed ERP compare and protected artifact guard completed"
require_text "$build_path" "bench-compare-memory passed: runs={d} memory indexed ERP compare and protected artifact guard completed"
require_text "$build_path" "bench-compare-concurrent passed: runs={d} concurrent compare and protected artifact guard completed"
require_text "$build_path" "bench-compare-proof passed: runs={d} disk/memory proof report plus strict concurrent insert and protected artifact guard completed"
require_text "$build_path" "bench-compare-proof-strict-chain passed: runs={d} strict disk/memory combined append proof plus strict concurrent insert and protected artifact guard completed"
require_text "$build_path" "bench-compare-disk-strict-chain passed: runs={d} disk strict combined append proof and protected artifact guard completed"
require_text "$build_path" "bench-compare-memory-strict-chain passed: runs={d} memory strict combined append proof and protected artifact guard completed"
require_text "$build_path" "sqlite_proof_summary.step.dependOn(&sqlite_audit_summary.step)"
require_text "$build_path" "sqlite_proof_summary.step.dependOn(&bench_compare_proof_summary.step)"
require_text "$build_path" "sqlite_proof_strict_chain_summary.step.dependOn(&sqlite_audit_summary.step)"
require_text "$build_path" "sqlite_proof_strict_chain_summary.step.dependOn(&bench_compare_proof_strict_summary.step)"

echo "docs guard passed: tasks.md, progress.md, and benchmark results cover ${#required_targets[@]} current proof targets and parity caveats"
