# sa_plugin_db Progress

## Tracking Basis

- Scope: `db` plugin manifest, CLI command surface, qmod registry/execution, and local table storage helpers.
- Progress rule: update this file, including percentages, after each completed feature.
- Current status: `16 / 16` tracked features completed (`100.0%`). The plugin builds, unit tests pass, installed-plugin smoke passes, qmod command examples are documented/tested locally, the manifest interface policy is documented, and the tracked qmod execution-surface expansion is complete.

## Feature Progress

- Feature 1 - `sap.json` plugin manifest and permissions: 100% (`db` artifact, `database` skill, project-scoped fs permissions, no net/env/process-spawn permissions).
- Feature 2 - Runtime descriptor and CLI command handler: 100% (`database` skill section exported through the runtime descriptor).
- Feature 3 - `db init <schema.sadb-schema>` schema bootstrap: 100% (emits generated `.sai` schema interface files).
- Feature 4 - `db register <query.sa>` qmod registry: 100% (SHA-256 payload storage and declared DB grant validation).
- Feature 5 - `db inspect <table|hash>` / `db status <table>` metadata inspection: 100% (table and qmod registry metadata reporting).
- Feature 6 - `db exec <hash> [--params <file>]` supported qmod execution: 100% for current recognized scalar/read/write/read-write/atomic cursor instruction shapes.
- Feature 7 - `db ingest <table> <csv|jsonl>` table ingestion: 100% (CSV and JSONL append into column segment files).
- Feature 8 - `db snapshot <table>` and `db restore <table> <epoch>` snapshots: 100% (metadata, schema, and segment snapshot/restore).
- Feature 9 - `db verify <table>` integrity checks: 100% (schema hash, segment hashes, row counts, and segment sizes).
- Feature 10 - `db compact <table>` segment compaction: 100% (many segments merged into one active segment).
- Feature 11 - `db lock <table>` table lock: 100% (locked metadata plus readonly file modes).
- Feature 12 - `db unlock <table>` table unlock: 100% (validates current table, clears locked state, restores writable file modes, and allows ingestion again). Verified with `zig build test` on 2026-06-08.
- Feature 13 - Installed-plugin smoke verification: 100% (`tests/smoke_installed.sh` builds, dev-installs, verifies `database` skills, and runs `sa db init/ingest/verify/lock/unlock/verify`). Verified on 2026-06-08.
- Feature 14 - Command-level qmod integration examples: 100% (`docs/qmod_examples.md` documents `sa db register` plus `sa db exec`, and `tests/smoke_installed.sh` verifies register/inspect/exec against a dev-installed plugin). Verified on 2026-06-08.
- Feature 15 - Stable exported interfaces decision: 100% (`sap.json` remains CLI-only with `interfaces: {}` for `0.1.0`; generated table `.sai` files are per-project outputs, not plugin-shipped stable interfaces). Documented in `docs/db_plugin_design.md` and verified with `jq -e '.interfaces == {} and .skills == ["database"]' sap.json` on 2026-06-08.
- Feature 16 - Broader qmod execution surface: 100% (added `and`, `or`, `xor`, `shl`, and `lshr` integer binary ops to the common qmod evaluator path; covered by scalar and read-only DB qmod unit tests plus installed-plugin smoke). Verified on 2026-06-08.

## Current Verification

- `zig build test` passes in `/home/vscode/projects/sa_plugins/sa_plugin_db`.
- `zig build` passes and produces `zig-out/lib/libdb.so` for the `linux-x86_64` artifact path in `sap.json`.
- `bash tests/smoke_installed.sh` passes and verifies the dev-installed plugin command path, including qmod register/inspect/exec and a bitwise DB filter qmod.
- `jq -e '.interfaces == {} and .skills == ["database"]' sap.json` passes and verifies the CLI-only manifest policy.

## Remaining Work

- None in the current tracked feature set.
