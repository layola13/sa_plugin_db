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

# --- VM query layer step 1: fuel metering + native column primitives ---
cat > vm_orders.sadb-schema <<'SCHEMA'
#def MAX_ROWS = 16
#def COL_ID_STRIDE = 8 // u64
#def COL_QTY_STRIDE = 8 // u64
#def COL_AMOUNT_STRIDE = 8 // u64
SCHEMA

cat > vm_orders.csv <<'CSV'
ID,QTY,AMOUNT
1,2,100
2,5,250
3,1,40
4,5,300
5,3,150
CSV

SA_PLUGIN_DEV=1 "$sa_bin" db init vm_orders.sadb-schema >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db ingest vm_orders vm_orders.csv | grep -F 'row_count: 5' >/dev/null

# Interpreter loop: sum of AMOUNT where QTY == 5 (250 + 300 = 550).
cat > vm_loop_sum.query.sa <<'QUERY'
grants [db_read:vm_orders]
@main(&col_qty: ptr, &col_amount: ptr, len: u64) -> u64:
L_ENTRY:
idx = add 0, 0
sum = add 0, 0
jmp L_COND
L_COND:
cond = ult idx, len
br cond -> L_BODY, L_EXIT
L_BODY:
qoff = mul idx, 8
qty = load col_qty+qoff as u64
hit = eq qty, 5
br hit -> L_MATCH, L_NEXT
L_MATCH:
aoff = mul idx, 8
amt = load col_amount+aoff as u64
sum = add sum, amt
jmp L_NEXT
L_NEXT:
idx = add idx, 1
jmp L_COND
L_EXIT:
return sum
QUERY

vm_loop_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register vm_loop_sum.query.sa)"
vm_loop_hash="$(printf '%s\n' "$vm_loop_output" | awk '/^Hash:/ {print $2}')"
test "${#vm_loop_hash}" -eq 64
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" | grep -F 'result_u64: 550' >/dev/null

# Native primitive: the same predicate + aggregate in one call.
cat > vm_prim_sum.query.sa <<'QUERY'
grants [db_read:vm_orders]
@main(&col_amount: ptr, &col_qty: ptr, len: u64) -> u64:
L_ENTRY:
total = col_sum_where_eq col_amount, len, col_qty, 5
return total
QUERY

vm_prim_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register vm_prim_sum.query.sa)"
vm_prim_hash="$(printf '%s\n' "$vm_prim_output" | awk '/^Hash:/ {print $2}')"
vm_prim_exec="$(SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_prim_hash")"
printf '%s\n' "$vm_prim_exec" | grep -F 'result_u64: 550' >/dev/null
printf '%s\n' "$vm_prim_exec" | grep -F 'fuel_used:' >/dev/null
printf '%s\n' "$vm_prim_exec" | grep -F 'fuel_limit: 1000000' >/dev/null

# Native primitive: whole-column total (100 + 250 + 40 + 300 + 150 = 840).
cat > vm_prim_total.query.sa <<'QUERY'
grants [db_read:vm_orders]
@main(&col_amount: ptr, len: u64) -> u64:
L_ENTRY:
total = col_sum col_amount, len
return total
QUERY

vm_total_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register vm_prim_total.query.sa)"
vm_total_hash="$(printf '%s\n' "$vm_total_output" | awk '/^Hash:/ {print $2}')"
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_total_hash" | grep -F 'result_u64: 840' >/dev/null

# Fuel: an explicit tiny budget terminates the loop module with a clean error.
if SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" --fuel 10 >fuel_small.out 2>fuel_small.err; then
    echo 'over-budget exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query fuel exhausted' fuel_small.err >/dev/null

# Fuel: the SA_DB_QMOD_FUEL environment variable sets the same budget.
if SA_DB_QMOD_FUEL=10 SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" >fuel_env.out 2>fuel_env.err; then
    echo 'env-budget exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query fuel exhausted' fuel_env.err >/dev/null

# Fuel: an invalid budget is a clean configuration error, not a silent default.
if SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" --fuel 0 >fuel_bad.out 2>fuel_bad.err; then
    echo 'zero-fuel exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'invalid DB fuel limit' fuel_bad.err >/dev/null

# Fuel: a runaway module is terminated by the default limit; the host stays up.
cat > vm_runaway.query.sa <<'QUERY'
grants [db_read:vm_orders]
@main(&col_id: ptr, len: u64) -> u64:
L_ENTRY:
zero = add 0, 0
jmp L_TOP
L_TOP:
v = load col_id+zero as u64
jmp L_TOP
QUERY

vm_runaway_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register vm_runaway.query.sa)"
vm_runaway_hash="$(printf '%s\n' "$vm_runaway_output" | awk '/^Hash:/ {print $2}')"
if timeout 60 env SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_runaway_hash" >fuel_run.out 2>fuel_run.err; then
    echo 'runaway exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query fuel exhausted' fuel_run.err >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" | grep -F 'result_u64: 550' >/dev/null

# Hash addressing: an unregistered hash fails cleanly.
if SA_PLUGIN_DEV=1 "$sa_bin" db exec 0000000000000000000000000000000000000000000000000000000000000000 >unknown.out 2>unknown.err; then
    echo 'unknown hash exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query hash is unknown' unknown.err >/dev/null

# --- VM write procedures + AOT escape hatch step 2 ---

# build-lib resolves its output through the dynamic loader for its
# post-link surface check, so the output path must be absolute.
if [[ -z "${SA_STD_DIR:-}" && "$sa_bin" == */zig-out/bin/sa ]]; then
    derived_std_dir="$(dirname "$(dirname "$sa_bin")")/sa_std"
    if [[ -d "$derived_std_dir" ]]; then
        export SA_STD_DIR="$derived_std_dir"
    fi
fi

# AOT read: the step-1 loop query, compiled natively through the
# toolchain's normal AOT path and registered against the same hash.
cat > vm_sum_aot.sai <<'CONTRACT'
@export sa_db_aot_abi_version() -> i64
@export sa_db_qmod_main(slots: ptr, slot_count: u64) -> u64
CONTRACT

cat > vm_sum_aot.sa <<'NATIVE'
@export sa_db_aot_abi_version() -> i64:
L_ENTRY:
    v = 1 as i64
    return v

@export sa_db_qmod_main(slots: ptr, slot_count: u64) -> u64:
L_ENTRY:
    qty_addr = load slots+0 as u64
    amt_addr = load slots+16 as u64
    len = load slots+32 as u64
    qty = bitcast qty_addr as ptr
    amt = bitcast amt_addr as ptr
    !qty_addr
    !amt_addr
    idx_slot = stack_alloc 8
    sum_slot = stack_alloc 8
    store idx_slot+0, 0 as u64
    store sum_slot+0, 0 as u64
    jmp L_LOOP
L_LOOP:
    idx = load idx_slot+0 as u64
    done = uge idx, len
    br done -> L_END, L_BODY
L_BODY:
    off = mul idx, 8
    qp = ptr_add qty, off
    q = load qp+0 as u64
    hit = eq q, 5
    !qp
    !q
    br hit -> L_MATCH, L_NEXT
L_MATCH:
    ap = ptr_add amt, off
    a = load ap+0 as u64
    sum_cur = load sum_slot+0 as u64
    sum_new = add sum_cur, a
    store sum_slot+0, sum_new as u64
    !ap
    !a
    !sum_cur
    !sum_new
    jmp L_NEXT
L_NEXT:
    next_idx = add idx, 1
    store idx_slot+0, next_idx as u64
    !next_idx
    !off
    !idx
    !done
    !hit
    jmp L_LOOP
L_END:
    result = load sum_slot+0 as u64
    !done
    !idx
    !len
    !qty
    !amt
    !slots
    !slot_count
    return result
NATIVE

"$sa_bin" build-lib vm_sum_aot.sa --contract vm_sum_aot.sai --kind shared -o "$PWD/libvm_sum_aot.so" >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db register-aot "$vm_loop_hash" --lib "$PWD/libvm_sum_aot.so" | grep -F 'abi_version: 1' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db inspect "$vm_loop_hash" | grep -F 'aot_symbol: sa_db_qmod_main' >/dev/null
vm_aot_exec="$(SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash")"
printf '%s\n' "$vm_aot_exec" | grep -F 'engine: aot' >/dev/null
printf '%s\n' "$vm_aot_exec" | grep -F 'result_u64: 550' >/dev/null

# AOT registration refuses a non-library without touching the
# record: the primitive module keeps running interpreted.
printf 'not a shared library\n' > fake.so
if SA_PLUGIN_DEV=1 "$sa_bin" db register-aot "$vm_prim_hash" --lib "$PWD/fake.so" >aot_bad.out 2>aot_bad.err; then
    echo 'register-aot with a text file unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB AOT library is invalid or changed since registration' aot_bad.err >/dev/null
vm_prim_exec_after="$(SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_prim_hash")"
printf '%s\n' "$vm_prim_exec_after" | grep -F 'result_u64: 550' >/dev/null
if printf '%s\n' "$vm_prim_exec_after" | grep -F 'engine: aot' >/dev/null; then
    echo 'failed register-aot silently switched the engine' >&2
    exit 1
fi

# Substituting a different library for a hash that already has an
# AOT record needs the explicit --replace flag.
if SA_PLUGIN_DEV=1 "$sa_bin" db register-aot "$vm_loop_hash" --lib "$PWD/fake.so" >aot_swap.out 2>aot_swap.err; then
    echo 'register-aot substitution without --replace unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query hash already has a registered AOT library' aot_swap.err >/dev/null

# Write procedure: register shows the procedure class, the
# interpreted run lands the bonus, and a fuel cut mid-procedure
# leaves every row untouched.
cat > vm_add_bonus.proc.sa <<'PROC'
grants [db_read:vm_orders, db_write:vm_orders]
@main(&col_qty: ptr, &col_amount: ptr, len: u64, bonus: u64) -> u64:
L_ENTRY:
idx = add 0, 0
count = add 0, 0
jmp L_COND
L_COND:
cond = ult idx, len
br cond -> L_BODY, L_EXIT
L_BODY:
qoff = mul idx, 8
qty = load col_qty+qoff as u64
hit = eq qty, 5
br hit -> L_MATCH, L_NEXT
L_MATCH:
aoff = mul idx, 8
amt = load col_amount+aoff as u64
new_amt = add amt, bonus
store col_amount+aoff, new_amt as u64
count = add count, 1
jmp L_NEXT
L_NEXT:
idx = add idx, 1
jmp L_COND
L_EXIT:
return count
PROC

printf '\x64\x00\x00\x00\x00\x00\x00\x00' > vm_bonus_params.bin
vm_proc_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db register vm_add_bonus.proc.sa)"
printf '%s\n' "$vm_proc_output" | grep -F 'kind: procedure' >/dev/null
printf '%s\n' "$vm_proc_output" | grep -F 'write_capability: true' >/dev/null
vm_proc_hash="$(printf '%s\n' "$vm_proc_output" | awk '/^Hash:/ {print $2}')"
test "${#vm_proc_hash}" -eq 64
SA_PLUGIN_DEV=1 "$sa_bin" db inspect "$vm_proc_hash" | grep -F 'write_table: vm_orders' >/dev/null

vm_snapshot_output="$(SA_PLUGIN_DEV=1 "$sa_bin" db snapshot vm_orders)"
vm_snapshot_epoch="$(printf '%s\n' "$vm_snapshot_output" | awk '/^epoch:/ {print $2}')"

SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_proc_hash" --params vm_bonus_params.bin | grep -F 'result_u64: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_total_hash" | grep -F 'result_u64: 1040' >/dev/null

if SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_proc_hash" --params vm_bonus_params.bin --fuel 5 >proc_fuel.out 2>proc_fuel.err; then
    echo 'write procedure over-budget exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query fuel exhausted' proc_fuel.err >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_total_hash" | grep -F 'result_u64: 1040' >/dev/null

# AOT write: restore the pre-procedure snapshot, run the same
# procedure natively, and land on the identical end state (2 rows
# updated, AMOUNT total 1040) as the interpreted run.
cat > vm_bonus_aot.sai <<'CONTRACT'
@export sa_db_aot_abi_version() -> i64
@export sa_db_qmod_main(slots: ptr, slot_count: u64) -> u64
CONTRACT

cat > vm_bonus_aot.sa <<'NATIVE'
@export sa_db_aot_abi_version() -> i64:
L_ENTRY:
    v = 1 as i64
    return v

@export sa_db_qmod_main(slots: ptr, slot_count: u64) -> u64:
L_ENTRY:
    qty_addr = load slots+0 as u64
    amt_addr = load slots+16 as u64
    len = load slots+32 as u64
    bonus = load slots+40 as u64
    qty = bitcast qty_addr as ptr
    amt = bitcast amt_addr as ptr
    !qty_addr
    !amt_addr
    idx_slot = stack_alloc 8
    count_slot = stack_alloc 8
    store idx_slot+0, 0 as u64
    store count_slot+0, 0 as u64
    jmp L_LOOP
L_LOOP:
    idx = load idx_slot+0 as u64
    done = uge idx, len
    br done -> L_END, L_BODY
L_BODY:
    off = mul idx, 8
    qp = ptr_add qty, off
    q = load qp+0 as u64
    hit = eq q, 5
    !qp
    !q
    br hit -> L_MATCH, L_NEXT
L_MATCH:
    ap = ptr_add amt, off
    a = load ap+0 as u64
    new_a = add a, bonus
    store ap+0, new_a as u64
    cnt = load count_slot+0 as u64
    cnt_new = add cnt, 1
    store count_slot+0, cnt_new as u64
    !ap
    !a
    !new_a
    !cnt
    !cnt_new
    jmp L_NEXT
L_NEXT:
    next_idx = add idx, 1
    store idx_slot+0, next_idx as u64
    !next_idx
    !off
    !idx
    !done
    !hit
    jmp L_LOOP
L_END:
    result = load count_slot+0 as u64
    !done
    !idx
    !len
    !bonus
    !qty
    !amt
    !slots
    !slot_count
    return result
NATIVE

"$sa_bin" build-lib vm_bonus_aot.sa --contract vm_bonus_aot.sai --kind shared -o "$PWD/libvm_bonus_aot.so" >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db restore vm_orders "$vm_snapshot_epoch" >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_total_hash" | grep -F 'result_u64: 840' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db register-aot "$vm_proc_hash" --lib "$PWD/libvm_bonus_aot.so" >/dev/null
vm_proc_aot_exec="$(SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_proc_hash" --params vm_bonus_params.bin)"
printf '%s\n' "$vm_proc_aot_exec" | grep -F 'engine: aot' >/dev/null
printf '%s\n' "$vm_proc_aot_exec" | grep -F 'result_u64: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_total_hash" | grep -F 'result_u64: 1040' >/dev/null

# Hash addressing: a tampered payload no longer matches its hash and is rejected.
printf 'x' >> ".sa/db/qmods/$vm_loop_hash.qmod"
if SA_PLUGIN_DEV=1 "$sa_bin" db exec "$vm_loop_hash" >tamper.out 2>tamper.err; then
    echo 'tampered payload exec unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'DB query payload is corrupted' tamper.err >/dev/null

# Read-only enforcement: a store under a read-only grant is rejected at register.
cat > vm_store.query.sa <<'QUERY'
grants [db_read:vm_orders]
@main(&col_id: ptr, len: u64) -> u64:
L_ENTRY:
store col_id+0, 1 as u64
return len
QUERY

if SA_PLUGIN_DEV=1 "$sa_bin" db register vm_store.query.sa >store.out 2>store.err; then
    echo 'store under read-only grant unexpectedly registered' >&2
    exit 1
fi
grep -F 'capability escalation' store.err >/dev/null

echo 'installed db plugin smoke passed'
