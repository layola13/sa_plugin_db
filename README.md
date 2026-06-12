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
- `sa_db_verify`
- `sa_db_compact`
- `sa_db_lock`
- `sa_db_unlock`
- `sa_db_update_u64_add`

Read-handle query calls:

- `sa_db_open_read_table`
- `sa_db_close_read_table`
- `sa_db_sum_u64_handle`
- `sa_db_count_u64_eq_handle`
- `sa_db_count_u64_cmp_handle`
- `sa_db_min_u64_handle`
- `sa_db_max_u64_handle`

Removed calls:

- `sa_db_sum_u64`
- `sa_db_count_u64_eq`
- `DB_SUM_U64`
- `DB_COUNT_U64_EQ`

The `sal` facade exposes matching macros such as `DB_OPEN_READ_TABLE`,
`DB_SUM_U64_HANDLE`, `DB_COUNT_U64_CMP_HANDLE`, `DB_MIN_U64_HANDLE`, and
`DB_MAX_U64_HANDLE`.

## Query Model

Read queries now use snapshots:

1. `sa_db_open_read_table` opens a read handle and copies immutable column bytes
   into a read snapshot.
2. `*_handle` query functions scan the in-memory snapshot.
3. `sa_db_close_read_table` releases the snapshot.

This makes repeated serial and concurrent reads fast because they no longer
reparse metadata or reread column files for every query. A handle remains a
snapshot: writes made after opening the handle are not visible until a new read
handle is opened.

Writes are protected by an in-process mutex, so same-process concurrent ingest
is correct. This is not a replacement for SQLite-style ACID, WAL, or
multi-process transaction isolation.

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
