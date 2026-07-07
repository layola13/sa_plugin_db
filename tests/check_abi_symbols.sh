#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'usage: check_abi_symbols.sh <db.sai> <libdb.so>' >&2
    exit 2
fi

sai_path="$1"
lib_path="$2"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -f "$sai_path" ]]; then
    echo "missing interface file: $sai_path" >&2
    exit 2
fi
if [[ ! -f "$lib_path" ]]; then
    echo "missing native library: $lib_path" >&2
    exit 2
fi

rg -o '^@extern[[:space:]]+(sa_db_[A-Za-z0-9_]+)' -r '$1' "$sai_path" | sort -u > "$tmp_dir/declared.txt"
nm -D --defined-only "$lib_path" | awk '{print $NF}' | rg '^sa_db_' | sort -u > "$tmp_dir/exported.txt"

declared_count="$(wc -l < "$tmp_dir/declared.txt")"
exported_count="$(wc -l < "$tmp_dir/exported.txt")"
if [[ "$declared_count" -eq 0 ]]; then
    echo "no sa_db extern declarations found in $sai_path" >&2
    exit 1
fi

comm -23 "$tmp_dir/declared.txt" "$tmp_dir/exported.txt" > "$tmp_dir/missing.txt"
comm -13 "$tmp_dir/declared.txt" "$tmp_dir/exported.txt" > "$tmp_dir/extra.txt"

if [[ -s "$tmp_dir/missing.txt" || -s "$tmp_dir/extra.txt" ]]; then
    if [[ -s "$tmp_dir/missing.txt" ]]; then
        echo 'db.sai externs missing from libdb.so:' >&2
        sed 's/^/  /' "$tmp_dir/missing.txt" >&2
    fi
    if [[ -s "$tmp_dir/extra.txt" ]]; then
        echo 'libdb.so exports sa_db_* symbols not declared in db.sai:' >&2
        sed 's/^/  /' "$tmp_dir/extra.txt" >&2
    fi
    echo "declared=$declared_count exported_sa_db=$exported_count" >&2
    exit 1
fi

echo "db ABI symbols match: declared=$declared_count exported_sa_db=$exported_count"
