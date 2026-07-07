#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
sa_bin="${SA_PLUGIN_DB_SA_BIN:-sa}"
skip_build="${SA_PLUGIN_DB_SKIP_BUILD:-0}"

normalize_home_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s' "$path"
    else
        printf '%s/%s' "$repo_root" "$path"
    fi
}

if [[ -z "${SA_PLUGINS_HOME:-}" ]]; then
    smoke_home="${SA_PLUGIN_DB_SMOKE_HOME:-$tmp_dir/sa_plugins_home}"
    export SA_PLUGINS_HOME="$(normalize_home_path "$smoke_home")"
elif [[ "$SA_PLUGINS_HOME" != /* ]]; then
    export SA_PLUGINS_HOME="$(normalize_home_path "$SA_PLUGINS_HOME")"
fi

if [[ "$skip_build" != "1" ]]; then
    cd "$repo_root"
    zig build test >/dev/null
    zig build >/dev/null
    SA_PLUGIN_DEV=1 "$sa_bin" plugin install --dev "$repo_root" >/dev/null
fi

SA_PLUGIN_DEV=1 "$sa_bin" plugin list | grep -F $'db	' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" skills | grep -F 'database' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" skills | grep -F 'db unlock <table>' >/dev/null

cd "$tmp_dir"
cat > flash_sale.sadb-schema <<'SCHEMA'
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64
#def COL_PRICE_STRIDE = 4 // f32
SCHEMA

cat > rows.csv <<'CSV'
ID,PRICE
1,9.5
2,10.25
CSV

cat > rows2.csv <<'CSV'
ID,PRICE
3,11.75
CSV

cat > rows.jsonl <<'JSONL'
{"ID":4,"PRICE":12.5}
{"ID":5,"PRICE":13.25}
JSONL

SA_PLUGIN_DEV=1 "$sa_bin" db init flash_sale.sadb-schema | grep -F 'flash_sale.sai' >/dev/null
test -f flash_sale.sai

SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows.csv | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'locked: false' >/dev/null
snapshot_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db snapshot flash_sale)"
printf '%s\n' "$snapshot_output" | grep -F 'row_count: 2' >/dev/null
snapshot_epoch="$(printf '%s\n' "$snapshot_output" | awk '/^epoch:/ {print $2}')"
test "$snapshot_epoch" = "1"

SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows2.csv | grep -F 'row_count: 3' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db compact flash_sale | grep -F 'segment_count: 1' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db lock flash_sale | grep -F 'locked: true' >/dev/null

if SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows.jsonl >locked_ingest.out 2>locked_ingest.err; then
    echo 'locked ingest unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB table is locked' locked_ingest.err >/dev/null

SA_PLUGIN_DEV=1 "$sa_bin" db unlock flash_sale | grep -F 'locked: false' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows.jsonl | grep -F 'row_count: 5' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 5' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db restore flash_sale "$snapshot_epoch" | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 2' >/dev/null

cat > sum_ids.query.sa <<'QUERY'
grants [db_read:flash_sale]
@main(&col_id: ptr, len: u64) -> u64:
L_ENTRY:
idx = add 0, 0
sum = add 0, 0
jmp L_COND
L_COND:
cond = ult idx, len
br cond -> L_BODY, L_EXIT
L_BODY:
offset = mul idx, 8
value = load col_id+offset as u64
sum = add sum, value
idx = add idx, 1
jmp L_COND
L_EXIT:
return sum
QUERY

register_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register sum_ids.query.sa)"
query_hash="$(printf '%s\n' "$register_output" | awk '/^Hash:/ {print $2}')"
test "${#query_hash}" -eq 64
SA_PLUGIN_DEV=1 "$sa_bin" db inspect "$query_hash" | grep -F 'grant: db_read:flash_sale' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$query_hash" | grep -F 'result_u64: 3' >/dev/null

cat > count_odd.query.sa <<'QUERY'
grants [db_read:flash_sale]
@main(&col_id: ptr, len: u64) -> u64:
L_ENTRY:
idx = add 0, 0
count = add 0, 0
jmp L_COND
L_COND:
cond = ult idx, len
br cond -> L_BODY, L_EXIT
L_BODY:
offset = mul idx, 8
value = load col_id+offset as u64
low = and value, 1
hit = eq low, 1
br hit -> L_MATCH, L_NEXT
L_MATCH:
count = add count, 1
jmp L_NEXT
L_NEXT:
idx = add idx, 1
jmp L_COND
L_EXIT:
return count
QUERY

odd_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register count_odd.query.sa)"
odd_hash="$(printf '%s\n' "$odd_output" | awk '/^Hash:/ {print $2}')"
test "${#odd_hash}" -eq 64
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$odd_hash" | grep -F 'result_u64: 1' >/dev/null

test -f flash_sale.manifest
find . -maxdepth 1 -type f -name 'flash_sale.meta.*' | grep -F 'flash_sale.meta.' >/dev/null
test -f flash_sale.col0.0.dat
test -f flash_sale.col1.0.dat
test -f .sa/db/qmods/$query_hash.qmod
test -f .sa/db/qmods/$query_hash.meta.json
test -f .sa/db/qmods/$odd_hash.qmod
test -f .sa/db/qmods/$odd_hash.meta.json

echo 'installed db plugin smoke passed'
