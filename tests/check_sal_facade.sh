#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'usage: check_sal_facade.sh <db.sai> <db.sal>' >&2
    exit 2
fi

sai_path="$1"
sal_path="$2"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -f "$sai_path" ]]; then
    echo "missing interface file: $sai_path" >&2
    exit 2
fi
if [[ ! -f "$sal_path" ]]; then
    echo "missing facade file: $sal_path" >&2
    exit 2
fi

rg -o '^@extern[[:space:]]+(sa_db_[A-Za-z0-9_]+)' -r '$1' "$sai_path" | sort -u > "$tmp_dir/declared.txt"
rg -o '@(sa_db_[A-Za-z0-9_]+)' -r '$1' "$sal_path" | sort -u > "$tmp_dir/facade_calls.txt"

declared_count="$(wc -l < "$tmp_dir/declared.txt")"
facade_count="$(wc -l < "$tmp_dir/facade_calls.txt")"
if [[ "$declared_count" -eq 0 ]]; then
    echo "no sa_db extern declarations found in $sai_path" >&2
    exit 1
fi

comm -23 "$tmp_dir/declared.txt" "$tmp_dir/facade_calls.txt" > "$tmp_dir/missing_facade.txt"
comm -13 "$tmp_dir/declared.txt" "$tmp_dir/facade_calls.txt" > "$tmp_dir/undeclared_facade.txt"

if [[ -s "$tmp_dir/missing_facade.txt" || -s "$tmp_dir/undeclared_facade.txt" ]]; then
    if [[ -s "$tmp_dir/missing_facade.txt" ]]; then
        echo 'db.sai externs not referenced by db.sal:' >&2
        sed 's/^/  /' "$tmp_dir/missing_facade.txt" >&2
    fi
    if [[ -s "$tmp_dir/undeclared_facade.txt" ]]; then
        echo 'db.sal references undeclared sa_db_* symbols:' >&2
        sed 's/^/  /' "$tmp_dir/undeclared_facade.txt" >&2
    fi
    echo "declared=$declared_count facade_calls=$facade_count" >&2
    exit 1
fi

echo "db.sal facade covers db.sai: declared=$declared_count facade_calls=$facade_count"
