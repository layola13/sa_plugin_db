# Issue 001: memory root create_u64_index returns InvalidFormat

Date: 2026-07-14

## Summary

`sa_plugin_db` memory-root SA smoke flows currently fail when creating a u64 index after schema initialization. The same schema, table, transaction insert, and read-back flow passes when the root is a normal filesystem path under `/tmp`.

## Reproduction

From `/home/vscode/projects/sa_plugins/sa_plugin_db`:

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa build-exe benchmark_test/db_memory_smoke.sa -o /tmp/db_memory_smoke.out --no-incremental
timeout 20s /tmp/db_memory_smoke.out
```

Observed:

```text
PANIC: code=9003
```

A focused probe using `DB_INIT_SCHEMA`, `DB_CREATE_U64_INDEX`, `DB_TX_BEGIN`, `DB_TX_INSERT_ROW`, `DB_TX_COMMIT`, `DB_OPEN_READ_TABLE`, and `DB_GET_ROW_U64_KEY_HANDLE` returns `SA_DB_ERR_INVALID_FORMAT` from `DB_CREATE_U64_INDEX` when the root is `:memory:...`.

The same focused probe passes when the root is `/tmp/scodex_db_probe_root`.

## Impact

SLA-native `scodex` live DB adapter tests cannot currently use DB memory roots for indexed round-trip coverage. The test has been switched to a `/tmp` filesystem root to keep using `sa_plugin_db` without SQLite while avoiding this DB memory-root regression.

## Notes

`benchmark_test/db_tx_smoke.sa` still passes, so the issue appears specific to memory-root schema/index materialization rather than transactions or indexed lookup in general.
