#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

protected=(
    benchmark_test/.bench_coltx
    benchmark_test/.bench_raw
    benchmark_test/.bench_sqlite
    sqlite_erp_indexed_write.db
)

if ! git diff --quiet -- "${protected[@]}"; then
    echo 'protected benchmark artifacts have tracked changes:' >&2
    git diff -- "${protected[@]}" --stat >&2
    echo 'restore or isolate benchmark outputs before trusting compare evidence' >&2
    exit 1
fi

echo 'protected benchmark artifacts are clean'
