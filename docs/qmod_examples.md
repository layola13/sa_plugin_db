# DB Qmod Examples

These examples assume the `db` plugin has been built and dev-installed:

```bash
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
```

## Read A Column Sum

Create a table schema:

```text
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64
#def COL_PRICE_STRIDE = 4 // f32
```

Initialize and ingest rows:

```bash
SA_PLUGIN_DEV=1 sa db init flash_sale.sadb-schema
SA_PLUGIN_DEV=1 sa db ingest flash_sale rows.csv
```

Example `rows.csv`:

```csv
ID,PRICE
1,9.5
2,10.25
```

Register a read-only qmod that sums `ID` values:

```sa
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
```

Run it through the command surface:

```bash
hash=$(SA_PLUGIN_DEV=1 sa db register sum_ids.query.sa | awk '/^Hash:/ {print $2}')
SA_PLUGIN_DEV=1 sa db inspect "$hash"
SA_PLUGIN_DEV=1 sa db exec "$hash"
```

Expected result:

```text
Executed: main
result_u64: 3
```

The repeatable command-level check lives in `tests/smoke_installed.sh`.

## Bitwise Filter

The qmod evaluator also supports integer bitwise and shift operations. This query counts rows whose `ID` has the low bit set:

```sa
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
```

`tests/smoke_installed.sh` verifies this shape against the installed plugin.
