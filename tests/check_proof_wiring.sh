#!/usr/bin/env bash
set -euo pipefail

build_path="${1:-build.zig}"

if [[ -z "$build_path" || ! -f "$build_path" ]]; then
    echo "build.zig is required for proof wiring checks" >&2
    exit 1
fi

require_text() {
    local needle="$1"
    if ! grep -F -- "$needle" "$build_path" >/dev/null; then
        echo "missing required proof wiring in $build_path: $needle" >&2
        exit 1
    fi
}

require_count_at_least() {
    local needle="$1"
    local minimum="$2"
    local count
    count=$(grep -F -- "$needle" "$build_path" | wc -l | tr -d ' ')
    if (( count < minimum )); then
        echo "missing required proof wiring in $build_path: $needle (found $count, expected at least $minimum)" >&2
        exit 1
    fi
}

require_text 'b.step("check-proof-wiring"'
require_text "tests/check_proof_wiring.sh"
require_text "test_step.dependOn(proof_wiring_step)"
require_text 'b.step("check-benchmark-parser-guards"'
require_text "tests/check_benchmark_parser_guards.sh"
require_text "test_step.dependOn(benchmark_parser_guards_step)"
require_text 'b.step("check-bounded-locks"'
require_text "tests/check_bounded_locks.sh"
require_text "test_step.dependOn(bounded_locks_step)"
require_text 'b.option(u32, "lock-wait-seconds"'
require_text "lock_wait_seconds_arg"
require_count_at_least '"flock", "-w", lock_wait_seconds_arg' 12

require_text "sqlite_audit_summary.step.dependOn(test_step)"
require_text "sqlite_audit_summary.step.dependOn(bench_step)"
require_text "sqlite_audit_summary.step.dependOn(benchmark_artifacts_step)"
require_text "benchmark executable builds"
require_text "bounded lock guard"
require_text "benchmark executable builds, benchmark parser guards, proof wiring, bounded lock guard, and protected benchmark artifacts are clean"
require_text "sqlite_link_std_work"
require_text "trap 'rm -rf \"\$work\"' EXIT"
require_text "--redefine-sym sqlite3_prepare=sa_std_stub_sqlite3_prepare"
require_text "--redefine-sym sqlite3_step=sa_std_stub_sqlite3_step"
require_text "--redefine-sym sqlite3_finalize=sa_std_stub_sqlite3_finalize"

require_text "bench-compare passed: runs={d} disk indexed ERP, memory indexed ERP, concurrent compare, and protected artifact guard completed"
require_text "bench_compare_summary.step.dependOn(&bench_compare_artifacts.step)"
require_text "bench_compare_step.dependOn(&bench_compare_summary.step)"
require_text "bench-compare-disk passed: runs={d} disk indexed ERP compare and protected artifact guard completed"
require_text "bench_compare_disk_summary.step.dependOn(&bench_compare_disk_artifacts.step)"
require_text "bench_compare_disk_step.dependOn(&bench_compare_disk_summary.step)"
require_text "bench-compare-memory passed: runs={d} memory indexed ERP compare and protected artifact guard completed"
require_text "bench_compare_memory_summary.step.dependOn(&bench_compare_memory_artifacts.step)"
require_text "bench_compare_memory_step.dependOn(&bench_compare_memory_summary.step)"
require_text "bench-compare-concurrent passed: runs={d} concurrent compare and protected artifact guard completed"
require_text "bench_compare_concurrent_summary.step.dependOn(&bench_compare_concurrent_artifacts.step)"
require_text "bench_compare_concurrent_step.dependOn(&bench_compare_concurrent_summary.step)"

require_text "bench_compare_proof_step.dependOn(&bench_compare_proof_disk.step)"
require_text "bench_compare_proof_memory.step.dependOn(&bench_compare_proof_disk.step)"
require_text "bench_compare_proof_concurrent.step.dependOn(&bench_compare_proof_memory.step)"
require_text "bench_compare_proof_artifacts.step.dependOn(&bench_compare_proof_concurrent.step)"
require_text "bench-compare-proof passed: runs={d} disk/memory proof report plus strict concurrent insert and protected artifact guard completed"
require_text "bench_compare_proof_summary.step.dependOn(&bench_compare_proof_artifacts.step)"
require_text "bench_compare_proof_step.dependOn(&bench_compare_proof_summary.step)"
require_text "bench_compare_proof_runs, false"

require_text "bench_compare_proof_strict_memory.step.dependOn(&bench_compare_proof_strict_disk.step)"
require_text "bench_compare_proof_strict_concurrent.step.dependOn(&bench_compare_proof_strict_memory.step)"
require_text "bench_compare_proof_strict_artifacts.step.dependOn(&bench_compare_proof_strict_concurrent.step)"
require_text "bench-compare-proof-strict-chain passed: runs={d} strict disk/memory combined append proof plus strict concurrent insert and protected artifact guard completed"
require_text "bench_compare_proof_strict_summary.step.dependOn(&bench_compare_proof_strict_artifacts.step)"
require_text "bench_compare_proof_strict_chain_step.dependOn(&bench_compare_proof_strict_summary.step)"
require_text "bench_compare_proof_runs, true"

require_text "bench-compare-disk-strict-chain passed: runs={d} disk strict combined append proof and protected artifact guard completed"
require_text "bench_compare_disk_strict_chain_summary.step.dependOn(&bench_compare_disk_strict_chain_artifacts.step)"
require_text "bench_compare_disk_strict_chain_step.dependOn(&bench_compare_disk_strict_chain_summary.step)"
require_text "bench-compare-memory-strict-chain passed: runs={d} memory strict combined append proof and protected artifact guard completed"
require_text "bench_compare_memory_strict_chain_summary.step.dependOn(&bench_compare_memory_strict_chain_artifacts.step)"
require_text "bench_compare_memory_strict_chain_step.dependOn(&bench_compare_memory_strict_chain_summary.step)"

require_text 'b.step("bench-compare-concurrent-strict-insert"'
require_text "bench_compare_concurrent_strict_insert.step.dependOn(&install_bench_compare.step)"
require_text "bench_compare_concurrent_strict_insert.step.dependOn(&benchmark_artifacts.step)"
require_text "bench_compare_concurrent_strict_insert_artifacts.step.dependOn(&bench_compare_concurrent_strict_insert.step)"
require_text "bench-compare-concurrent-strict-insert passed: runs={d} strict raw/coltx concurrent insert proof and protected artifact guard completed"
require_text "bench_compare_concurrent_strict_insert_summary.step.dependOn(&bench_compare_concurrent_strict_insert_artifacts.step)"
require_text "bench_compare_concurrent_strict_insert_step.dependOn(&bench_compare_concurrent_strict_insert_summary.step)"

require_text "sqlite-proof passed: sqlite-audit plus runs={d} disk/memory/concurrent performance proof completed"
require_text "disk combined append remains report-only unless strict-chain is explicitly requested"
require_text "sqlite_proof_summary.step.dependOn(&sqlite_audit_summary.step)"
require_text "sqlite_proof_summary.step.dependOn(&bench_compare_proof_summary.step)"
require_text "sqlite_proof_step.dependOn(&sqlite_proof_summary.step)"

require_text "sqlite-proof-strict-chain passed: sqlite-audit plus runs={d} strict disk/memory combined append proof and strict concurrent insert completed"
require_text "sqlite_proof_strict_chain_summary.step.dependOn(&sqlite_audit_summary.step)"
require_text "sqlite_proof_strict_chain_summary.step.dependOn(&bench_compare_proof_strict_summary.step)"
require_text "sqlite_proof_strict_chain_step.dependOn(&sqlite_proof_strict_chain_summary.step)"

echo "proof wiring guard passed: sqlite-audit and sqlite-proof dependency chains are intact"
