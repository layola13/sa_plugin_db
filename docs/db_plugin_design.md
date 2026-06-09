# sa_plugin_db Design Notes

## Purpose

`sa_plugin_db` provides a local, file-backed database workflow for SA projects. It is intentionally scoped to project files: the manifest permits project filesystem reads/writes/creates/deletes and denies network, environment, and process-spawn access.

## Command Surface

- `sa db init <schema.sadb-schema>` emits a generated `.sai` schema interface.
- `sa db ingest <table> <csv|jsonl>` appends data into column segment files.
- `sa db inspect <table|hash>` reports table or qmod metadata.
- `sa db status <table>` aliases table inspection.
- `sa db snapshot <table>` stores a copy of table metadata, schema, and segments under `.sa/db/snapshots/`.
- `sa db restore <table> <epoch>` restores a previous snapshot epoch.
- `sa db verify <table>` validates schema hash, segment hashes, row counts, and segment sizes.
- `sa db compact <table>` rewrites many segments into one segment.
- `sa db lock <table>` records the table as locked and applies readonly file modes.
- `sa db unlock <table>` validates the table, clears the locked bit, reapplies writable file modes, and permits new writes.
- `sa db register <query.sa>` registers a qmod payload by SHA-256 hash with declared DB grants.
- `sa db exec <hash> [--params <file>]` executes a registered qmod when the instruction shape and grants are supported.

## Storage Layout

- `<table>.sadb-schema` is the source schema.
- `<table>.meta` is JSON metadata for the active table.
- `<table>.col<column_index>.<segment_id>.dat` stores columnar segment bytes.
- `.sa/db/qmods/<hash>.qmod` stores registered query payloads.
- `.sa/db/qmods/<hash>.meta.json` stores qmod registry metadata.
- `.sa/db/snapshots/<table>/<epoch>/` stores snapshot copies.

## Safety Rules

- Qmods must declare explicit grants such as `db_read:<table>`, `db_write:<table>`, or `db_atomic_cursor:<table>`.
- Registration rejects DB pointer and atomic cursor shapes that are not covered by grants or schema columns.
- Exec validates registered qmod hashes before running.
- Table writes reject locked tables.
- Unlock validates current segment hashes before clearing the lock.

## Supported Qmod Execution Surface

- Scalar qmods with `u64` parameters and a `u64` return.
- Read-only DB qmods over declared `db_read:<table>` columns.
- Write-only and read-write DB qmods over declared `db_write:<table>` / `db_read:<table>` grants.
- Atomic cursor qmods using declared `db_atomic_cursor:<table>` grants.
- Control flow with labels, `jmp`, `br`, and `return` in supported DB evaluator paths.
- Integer binary ops: `add`, `sub`, `mul`, `and`, `or`, `xor`, `shl`, `lshr`, `eq`, `ne`, `ult`, `ule`, `ugt`, and `uge`.
- Floating comparisons through `fcmp_gt`, `fcmp_ge`, `fcmp_lt`, `fcmp_le`, `fcmp_eq`, and `fcmp_ne` where the loaded values use the evaluator's bit representation.

## Interface Policy

The plugin is intentionally CLI-only for version `0.1.0`: `sap.json` keeps `interfaces` as `{}` and exposes capability through the runtime descriptor command handler plus the `database` skill section. Generated table `.sai` files are per-project schema outputs from `sa db init`; they are not stable plugin API files shipped by the manifest.

Add a manifest `.sai` or `.sal` only after there is a stable low-level ABI that SA programs should import directly. Until then, command-level compatibility is the supported surface.

## Verification

- Unit tests: `zig build test`.
- Build artifact check: `zig build` produces `zig-out/lib/libdb.so`, matching `sap.json`.
- Manifest interface policy: `jq -e '.interfaces == {} and .skills == ["database"]' sap.json`.
- Installed-plugin smoke: `bash tests/smoke_installed.sh` builds, dev-installs with `SA_PLUGIN_DEV=1`, confirms the `database` skill, and runs `sa db init/ingest/verify/lock/unlock/verify` in an isolated project directory.
- Qmod command example: `docs/qmod_examples.md` shows `sa db register`, `sa db inspect`, and `sa db exec`; the same flow is verified by `tests/smoke_installed.sh`, including a bitwise `and` DB filter qmod.
