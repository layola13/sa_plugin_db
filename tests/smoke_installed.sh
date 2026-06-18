#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cd "$repo_root"
zig build test >/dev/null
zig build >/dev/null
SA_PLUGIN_DEV=1 sa plugin install --dev "$repo_root" >/dev/null

SA_PLUGIN_DEV=1 sa plugin list | grep -F $'db	' >/dev/null
SA_PLUGIN_DEV=1 sa skills | grep -F 'database' >/dev/null
SA_PLUGIN_DEV=1 sa skills | grep -F 'db unlock <table>' >/dev/null

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

SA_PLUGIN_DEV=1 sa db init flash_sale.sadb-schema | grep -F 'flash_sale.sai' >/dev/null
test -f flash_sale.sai

SA_PLUGIN_DEV=1 sa db ingest flash_sale rows.csv | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 sa db verify flash_sale | grep -F 'locked: false' >/dev/null
SA_PLUGIN_DEV=1 sa db lock flash_sale | grep -F 'locked: true' >/dev/null
SA_PLUGIN_DEV=1 sa db unlock flash_sale | grep -F 'locked: false' >/dev/null
SA_PLUGIN_DEV=1 sa db verify flash_sale | grep -F 'epoch: 3' >/dev/null

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

register_output="$(SA_PLUGIN_DEV=1 sa db register sum_ids.query.sa)"
query_hash="$(printf '%s\n' "$register_output" | awk '/^Hash:/ {print $2}')"
test "${#query_hash}" -eq 64
SA_PLUGIN_DEV=1 sa db inspect "$query_hash" | grep -F 'grant: db_read:flash_sale' >/dev/null
SA_PLUGIN_DEV=1 sa db exec "$query_hash" | grep -F 'result_u64: 3' >/dev/null

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

odd_output="$(SA_PLUGIN_DEV=1 sa db register count_odd.query.sa)"
odd_hash="$(printf '%s\n' "$odd_output" | awk '/^Hash:/ {print $2}')"
test "${#odd_hash}" -eq 64
SA_PLUGIN_DEV=1 sa db exec "$odd_hash" | grep -F 'result_u64: 1' >/dev/null

test -f flash_sale.manifest
find . -maxdepth 1 -type f -name 'flash_sale.meta.*' | grep -F 'flash_sale.meta.' >/dev/null
test -f flash_sale.col0.0.dat
test -f flash_sale.col1.0.dat
test -f .sa/db/qmods/$query_hash.qmod
test -f .sa/db/qmods/$query_hash.meta.json
test -f .sa/db/qmods/$odd_hash.qmod
test -f .sa/db/qmods/$odd_hash.meta.json

echo 'installed db plugin smoke passed'
