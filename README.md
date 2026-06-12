# SA DB Plugin

`sa_plugin_db` is the native database plugin for SA. It provides a local,
file-backed column store with SA-facing `sai` and `sal` interfaces.

The current development API is intentionally breaking: the old direct query
ABI has been removed. Query code must use read handles.

## Plugin Metadata

- Plugin: `db` v0.1.0
- Manifest: `sap.json`
- Native library: `zig-out/lib/libdb.so`
- Public interfaces: `db.sai`, `db.sal`
- Skill: `database`
- Permissions: project-local filesystem read/write/create/delete only; no net,
  no env access, no process spawning

## Build And Install

```bash
zig build test
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
sa plugin list
```

## SA-Facing API

The plugin exposes `sai` and `sal` interfaces through `sap.json`:

```json
"interfaces": {
  "sai": { "path": "db.sai" },
  "sal": { "path": "db.sal" }
}
```

Core native calls:

- `sa_db_init_schema`
- `sa_db_remove_table`
- `sa_db_ingest_columns`
- `sa_db_insert_row`
- `sa_db_upsert_row_u64_key`
- `sa_db_create_u64_index`
- `sa_db_delete_u64_key`
- `sa_db_snapshot`
- `sa_db_restore`
- `sa_db_recover`
- `sa_db_verify`
- `sa_db_compact`
- `sa_db_lock`
- `sa_db_unlock`
- `sa_db_update_u64_add`

Read-handle query calls:

- `sa_db_open_read_table`
- `sa_db_close_read_table`
- `sa_db_snapshot_info_handle`
- `sa_db_column_info_handle`
- `sa_db_sum_u64_handle`
- `sa_db_count_u64_eq_handle`
- `sa_db_count_u64_cmp_handle`
- `sa_db_find_u64_handle`
- `sa_db_range_u64_handle`
- `sa_db_get_u64_handle`
- `sa_db_project_rows_handle`
- `sa_db_get_row_handle`
- `sa_db_get_row_u64_key_handle`
- `sa_db_min_u64_handle`
- `sa_db_max_u64_handle`

Public status constants include `SA_DB_ERR_CONSTRAINT` for writes that violate
unique indexes.

Removed calls:

- `sa_db_sum_u64`
- `sa_db_count_u64_eq`
- `DB_SUM_U64`
- `DB_COUNT_U64_EQ`

The `sal` facade exposes matching macros such as `DB_OPEN_READ_TABLE`,
`DB_SNAPSHOT_INFO_HANDLE`, `DB_COLUMN_INFO_HANDLE`, `DB_SUM_U64_HANDLE`,
`DB_COUNT_U64_CMP_HANDLE`, `DB_FIND_U64_HANDLE`, `DB_RANGE_U64_HANDLE`,
`DB_GET_U64_HANDLE`, `DB_PROJECT_ROWS_HANDLE`, `DB_GET_ROW_HANDLE`,
`DB_GET_ROW_U64_KEY_HANDLE`, `DB_INGEST_COLUMNS`, `DB_INSERT_ROW`,
`DB_UPSERT_ROW_U64_KEY`, `DB_CREATE_U64_INDEX`, `DB_DELETE_U64_KEY`,
`DB_MIN_U64_HANDLE`, `DB_MAX_U64_HANDLE`, `DB_SNAPSHOT`, `DB_RESTORE`,
and `DB_RECOVER`.

## Query Model

Read queries now use snapshots:

1. `sa_db_open_read_table` opens a read handle and copies immutable column bytes
   into a read snapshot.
2. `sa_db_snapshot_info_handle` and `sa_db_column_info_handle` expose snapshot
   row count, column count, row width, epoch, column stride, primitive type code,
   and metadata string lengths without requiring callers to parse JSON meta.
3. `*_handle` query functions scan the in-memory snapshot; `find_u64` and
   `count_u64_cmp` use a persisted sorted `u64 -> row` index when one exists for
   the column. `project_rows_handle` copies only selected columns for a batch of
   row indices. `get_row_handle` copies a full fixed-width row by snapshot row
   index, while `get_row_u64_key_handle` requires a unique `u64` index and copies
   the matching row into the caller's row buffer.
4. `sa_db_close_read_table` releases the snapshot.

Primitive type codes exported through `db.sal` match the schema compiler enum:
`SA_DB_TYPE_I1`, `I8`, `I16`, `I32`, `I64`, `U8`, `U16`, `U32`, `U64`, `F32`,
`F64`, `PTR`, `BLOB_HANDLE`, and `V128`. ERP code can map `i1` to boolean,
`i64`/`u64` to scaled decimals or date/time encodings, and fixed-width columns
to packed row buffers while higher-level decimal/date/string-dict APIs are added.

`sa_db_range_u64_handle` / `DB_RANGE_U64_HANDLE` returns row indices for an
inclusive `[min, max]` range over an indexed `u64` column. It is designed for ERP
list pages and key/date/order-number windows: callers pass `offset`, `limit`, and
a `u64` row-index buffer; the API returns `total` matches and `written` row
indices in index order. The target column must have a persisted `u64` index, so
range pagination uses binary-search bounds instead of a full scan.
Use `sa_db_get_row_handle` / `DB_GET_ROW_HANDLE` to materialize any returned row
index into a fixed-width row buffer.
Use `sa_db_project_rows_handle` / `DB_PROJECT_ROWS_HANDLE` when a list page only
needs selected columns. The output is packed row-major: for each row index in
the input order, bytes for each requested column are appended in the requested
column order. The call returns `written_rows` and `required_bytes`; a too-small
output buffer returns `SA_DB_ERR_CURSOR_OVERFLOW` with `required_bytes` set.

This makes repeated serial and concurrent reads fast because they no longer
reparse metadata or reread column files for every query. A handle remains a
snapshot: writes made after opening the handle are not visible until a new read
handle is opened.

Writes are protected by an in-process mutex, so same-process concurrent ingest
is correct. Storage writes now use file-level atomic replacement: data is first
written to a temporary file in the destination directory, synced, renamed over
the active file, and the parent directory is synced on Linux when available.
Table commits are selected through an active manifest that points at a versioned
metadata file (`<table>.meta.<epoch>`). Mutating existing column data writes a new
versioned column file and then advances the manifest, so a crash before manifest
replacement leaves the previous epoch readable. Qmod read/write paths use the
same active-manifest protocol as the public table APIs. Segment metadata records
SHA-256 and byte counts. U64 index files are also versioned, hashed, snapshotted,
restored, and rebuilt on ingest/update/compact/qmod writes. Verification checks
schema hash, segment hash, index hash, recorded size, and the expected
`rows * column_stride` size. `recover` scans versioned metadata files and rebuilds
the manifest to the highest valid epoch, which covers corrupted or missing
manifest files after an interrupted commit.

`sa_db_create_u64_index(..., unique=1)` now acts as a real uniqueness
constraint. Creating the unique index rejects existing duplicate values, and
later column ingest, fixed-width row insert, update, compact, and Qmod commit
paths rebuild the persisted index before committing metadata. If duplicate keys
would appear, the write is rejected with `SA_DB_ERR_CONSTRAINT` and the active
manifest remains on the previous table epoch.

For ERP-style writes, `sa_db_insert_row` / `DB_INSERT_ROW` now accepts one
fixed-width row laid out exactly as the active schema's column strides. The
implementation splits the row into column slices and commits through the same
column ingest path, so the write advances the table epoch and rebuilds any
persisted `u64` indexes.

`sa_db_upsert_row_u64_key` / `DB_UPSERT_ROW_U64_KEY` upserts one fixed-width row
by a unique `u64` key. The target column must already have a unique `u64` index.
When the key exists, the existing row is atomically replaced by rewriting the
table into a new column segment, rebuilding indexes, and advancing the epoch;
`out_inserted` is `0`. When the key is absent, the row is appended through the
same indexed ingest path and `out_inserted` is `1`. The `expected` key must match
the `u64` value encoded in the row's key column, otherwise the call returns
`SA_DB_ERR_INVALID_FORMAT` without committing a new epoch.

`sa_db_delete_u64_key` / `DB_DELETE_U64_KEY` deletes one row by a unique `u64`
key. The target column must already have a unique `u64` index, so the operation
has primary-key semantics instead of deleting an arbitrary non-unique match. The
delete rewrites the remaining rows into a new column segment, rebuilds indexes,
advances the epoch, and returns `SA_DB_ERR_NOT_FOUND` when the key is absent.

This is still not a replacement for SQLite-style ACID, WAL, general
primary/secondary index planning, or multi-process transaction isolation. The
v0.2 ERP foundation work is to add those missing database semantics without
losing the fast read-handle scan path.

## ERP Foundation Roadmap

The next development target is small/mid ERP suitability, not only OLAP SUM
benchmarks. The required baseline is:

- SA ERP benchmarks covering customers, products, inventory movement, sales
  orders, invoices/payments, and journal entries, with SQLite comparisons for
  single-threaded, concurrent, and mixed read/write workloads.
- Typed ERP storage for signed decimals, dates/times, booleans, nullable values,
  and dictionary-encoded strings. Primitive schema type codes are now exposed;
  higher-level typed column families still need dedicated encode/query helpers.
- Row-oriented public operations on top of the column store: fixed-width insert
  read by row index or unique `u64` key, upsert, range query handles, and delete
  by unique `u64` key exist now. Projected batch reads now cover the first ERP
  list-page shape; next is typed column families beyond raw fixed-width bytes.
- Generalized primary-key and secondary indexes beyond the current persisted
  `u64` point-lookup/unique index, including date/customer/product filters and
  inventory/order workflows.
- Transaction commit semantics, followed by optional WAL and async batch flush.
- mmap snapshots, block min/max indexes, predicate pushdown, and later SIMD
  aggregation as performance work after the reliability/data-model baseline.

## Benchmark

Benchmark sources and raw run data live in `benchmark_test/`.

All benchmark programs are written in SA. SQLite comparison programs use SA
`@extern sqlite3_*` calls to the system SQLite library.

Dataset:

- 50,000 member rows
- Columns: `id`, `plan`, `status`, `points`, all `u64`
- Concurrent query: 4 workers, 100 total full-table SUM queries
- Concurrent insert: 4 workers, 12,500 rows each

Run db benchmarks:

```bash
cd /home/vscode/projects/sa_plugins/sa_plugin_db/benchmark_test
sa build-exe db_interface_smoke.sa -o db_interface_smoke.out --no-incremental
./db_interface_smoke.out

sa build-exe db_member_bench.sa -o db_member_bench.out --no-incremental
./db_member_bench.out

sa build-exe db_concurrent_bench.sa -o db_concurrent_bench.out --no-incremental
./db_concurrent_bench.out
```

Latest 5-run median results:

| Operation | db plugin | SQLite | Fastest |
| --- | ---: | ---: | --- |
| create/init | 6.711 ms | 0.596 ms | SQLite |
| bulk insert, 50k rows | 19.012 ms | 41.081 ms | db plugin |
| single SUM before update | 5.359 ms | 3.256 ms | SQLite |
| update all rows | 8.897 ms | 9.838 ms | db plugin |
| single SUM after update | 3.683 ms | 2.803 ms | SQLite |
| count `plan = 1` | 1.108 ms | 2.253 ms | db plugin |
| compact/vacuum | 20.293 ms | 5.597 ms | SQLite |
| verify/integrity | 11.624 ms | 3.518 ms | SQLite |
| serial 100x SUM with read handle | 122.111 ms | 308.089 ms | db plugin |
| concurrent 4x25 SUM with read handles | 48.385 ms | 120.165 ms | db plugin |
| concurrent insert, 4x12,500 rows | 55.618 ms | 90.713 ms | db plugin |

Summary:

- Reused read-handle queries are faster than SQLite in this benchmark.
- Concurrent read-handle SUM is about 2.5x faster than the SQLite comparison.
- Concurrent insert is about 1.6x faster than the SQLite comparison.
- Single SUM queries can still favor SQLite when db handle open/snapshot cost is
  included.
- SQLite remains stronger for SQL, indexes, ACID, WAL, crash recovery,
  compact/vacuum, and integrity checks.

Detailed results: `benchmark_test/RESULTS.md`.

## Verification Status

The current development state has been verified with:

```bash
zig build test
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
```

The installed plugin exposes only the new read-handle query symbols; the removed
direct query symbols are no longer exported from `libdb.so`.
