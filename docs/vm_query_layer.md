# VM Query Layer — Step 1: Read-Only Query Modules + Fuel Metering

Status: implemented (step 1 of the VM support plan recorded in sala
`content/10_db/07_vm_support.html`). Scope delivered: fuel/step metering
for every qmod execution, native column primitives callable from
read-only query modules, examples, unit tests, and installed-plugin
smoke coverage. Write-path VM modules and AOT registration remain step 2
and are not part of this change.

## 1. Recon conclusions (what existed before this change)

- The qmod mechanism is the VM embryo the design calls for: modules are
  SA-text sources registered by content hash
  (`.sa/db/qmods/<sha256>.qmod` + `<sha256>.meta.json`), addressed by the
  SHA-256 hex of the payload, and executed with
  `sa db exec <hash> [--params <file>]`. Registration validates the
  module's declared grants (`db_read` / `db_write` / `db_atomic_cursor`)
  against the instructions it contains (e.g. a `store` under a read-only
  grant is rejected at register time with `DbCapabilityEscalation`).
- The executor in `src/db_stub.zig` is a register-machine interpreter
  over the module source with five shapes (scalar, read-only DB,
  write DB, read-write DB, atomic cursor). Read-only modules already
  iterate snapshot columns with `load` + labels/`jmp`/`br`; the
  evaluator loads the table through the active-manifest snapshot path
  (`loadReadTable` merges the active segments), so modules always run
  on a consistent read snapshot.
- Step accounting existed only as a hard-coded per-evaluator cap:
  each DB evaluator stopped after 1,000,000 executed lines by returning
  `UnsupportedOperation`. That was wrong in three ways: the limit was
  not configurable, the error was the shape-mismatch signal (so an
  over-budget read-only module silently fell through to the remaining
  evaluators and finished with the generic code 12), and the budget was
  per evaluator, not per exec. The scalar evaluator had no cap at all.
- Executing real SAB bytecode from inside the plugin is not reachable
  today: SAB decoding/execution lives in the host (`sci/src/sab.zig`,
  `sci/src/interp.zig`, ~4,100 lines importing the referee, flattener
  symbol tables, capability and policy modules) and no plugin-facing
  host service exposes it — the plugin bridge uses SAB only for
  host-side encode/decode helpers. The interpreter also carries a
  registered defect (segfault when SA functions are called with
  `&scalar` arguments, sci interpreter surface). Importing that
  interpreter into `libdb.so` would put an un-metered, known-fragile
  interpreter inside the database's trust boundary — exactly the blast
  radius the design page warns about. See the registrations in §6.

## 2. Design decision (step 1 form)

Step 1 grows the existing qmod evaluator into the metered read-only
query VM, instead of bolting on a second execution engine:

- Payloads, hash addressing, the registry layout, and grant validation
  are unchanged. Existing registered modules keep working byte-for-byte.
- The interpreter is the orchestration tier of the design's two-tier
  model; whole-column predicate/aggregate work moves into native
  column primitives (§4) that modules call.
- Fuel metering (§3) is a precondition satisfied before any new module
  surface was added, and it covers all five evaluator shapes, not just
  the read-only one.
- Modules remain application-layer files referenced by hash; nothing is
  embedded into table data files, and the schema stays compile-time
  fixed — no new surface lets a module touch schema or segment files.

The end-state bytecode remains SAB per the design page; the bridge to
SAB payloads is registered as host work in §6 rather than faked here.

## 3. Fuel metering

Landing layer: **the db plugin's own evaluator** (`src/db_stub.zig`).
One `FuelMeter` is created per `execQuery` call and shared by every
evaluator shape the exec attempts, so shape probing cannot multiply
the total work of one execution.

- Charge model: 1 step per executed instruction in any evaluator
  (including the scalar evaluator). Native column primitives charge
  1 additional step per scanned row, paid up front before the scan.
- Limit resolution, in order: explicit `--fuel <steps>` on
  `sa db exec` → the `SA_DB_QMOD_FUEL` environment variable → the
  default of 1,000,000 steps (identical to the historical cap, so
  previously accepted modules are unaffected).
- A limit of 0 or an unparsable value is a hard configuration error
  (`InvalidFuelLimit` / CLI: `invalid DB fuel limit`); there is no
  silent fallback to the default.
- Exhaustion returns `FuelExhausted` (CLI: `error[SA-DB-CLI]: DB query
  fuel exhausted`), which aborts the exec immediately — it is never
  mistaken for a shape mismatch and never falls through to another
  evaluator, so a runaway write-shaped module cannot be re-executed by
  a second shape either. Termination is a clean error return from the
  plugin command; the host process stays alive (verified in smoke by
  executing a good module right after the runaway one).
- Observability: successful exec output now ends with
  `fuel_used: <n>` and `fuel_limit: <n>` lines.
- Environment reading follows the codebase's existing pattern
  (table.zig's `SA_DB_UNSAFE_NO_SYNC` detection): `/proc/self/environ`
  on Linux, inherited-at-exec only, because the plugin is linked
  without libc. Non-Linux platforms use the flag/default only.

Granularity limits, stated plainly: metering counts evaluator
instructions and primitive-scanned rows, not wall-clock time and not
bytes touched by a single `load` (a load is one cell by construction).
Host-side work outside the evaluator (payload hash check, snapshot
load) is bounded by the registry's 16 MiB payload cap and table size,
and is not metered.

## 4. Native column primitives (read-only tier)

A primitive call is an assignment whose operator is the primitive
name, e.g. `total = col_sum col_amount, len`. Arguments are column
pointer registers declared in the module signature (bound to the
granted table by the existing parameter machinery) plus value
registers/literals. Primitives run natively over the snapshot's merged
column bytes.

| Primitive | Arguments | Result |
| --- | --- | --- |
| `col_sum` | `(ptr, len)` | wrapping u64 sum of the first `len` rows |
| `col_min` | `(ptr, len)` | smallest loaded value; `len` must be > 0 |
| `col_max` | `(ptr, len)` | largest loaded value; `len` must be > 0 |
| `col_count_eq` | `(ptr, len, value)` | rows whose value equals `value` |
| `col_count_range` | `(ptr, len, lo, hi)` | rows with `lo <= value < hi` |
| `col_sum_where_eq` | `(sum_ptr, len, key_ptr, key)` | sum of `sum_ptr` over rows where `key_ptr == key` |

Semantics and limits:

- `len` is a row count and may not exceed the rows present in the
  snapshot column (`InvalidFormat` otherwise — no overscan).
- Only integer-typed columns (u8/u16/u32/u64, i8/i16/i32/i64, as
  loaded by `loadColumnValue`) are supported. Float columns are
  rejected with `ColumnTypeMismatch`, because aggregating their
  loaded bit patterns would be meaningless.
- Comparisons use the loaded u64 cell representation; signed columns
  therefore compare as two's-complement bit patterns. Sums wrap,
  matching the interpreter's `add` semantics.
- `col_min` / `col_max` over zero rows are `InvalidFormat` (there is
  no identity element to return); `col_sum` over zero rows is 0.
- An unknown `col_*` operator is `InvalidFormat`, not a shape
  mismatch: once a line names the primitive family, its errors are
  module bugs and are reported as such.
- Primitives exist only in the read-only evaluator in step 1. A
  module needs a `db_read` grant naming the table; pointers resolve
  only against that table's snapshot columns, so primitives cannot
  reach outside the granted table.

## 5. Examples and acceptance

Runnable examples live in `docs/vm_examples/` (schema, CSV, a loop
module and primitive modules computing the same query, and a runaway
module for fuel). `tests/smoke_installed.sh` carries the end-to-end
acceptance against a dev-installed plugin:

- Predicate + aggregate, two ways: the interpreter loop module and
  the `col_sum_where_eq` module both compute
  `sum(AMOUNT where QTY = 5) = 550` over the 5-row `vm_orders`
  table; the expected value was also computed independently from the
  CSV (250 + 300). `col_sum` over AMOUNT returns 840.
- Fuel: `--fuel 10` and `SA_DB_QMOD_FUEL=10` both terminate the loop
  module with `DB query fuel exhausted`; `--fuel 0` is
  `invalid DB fuel limit`; the runaway module
  (`docs/vm_examples/runaway.query.sa`) is terminated by the default
  limit under a 60 s timeout and a subsequent good exec still
  returns 550.
- Hash addressing: exec of an unregistered 64-hex hash fails with
  `DB query hash is unknown`; appending one byte to a registered
  payload makes exec fail with `DB query payload is corrupted`.
- Read-only enforcement: registering a module that contains a
  `store` under only a `db_read` grant fails with
  `DB query capability escalation`.
- Unit tests in `src/db_stub.zig` cover: all six primitives against
  loop-computed results on a 5-row table, fuel exhaustion for an
  unbounded module at an explicit limit and at the default limit,
  an over-budget bounded module, `fuel_used`/`fuel_limit` reporting,
  float-column and overscan rejection, and unknown-primitive
  rejection. `src/plugin.zig` tests cover the two new CLI
  diagnostics.

Regression gate: `zig build test` on the pristine base tree and on
this change are compared by failure name set (see §7).

## 6. Registrations (not fixed here, by design)

- REG-VM-1 (host/sci): no plugin-facing SAB execution service
  exists. Supporting SAB qmod payloads needs a host decision:
  either expose SAB execution to plugins through the plugin ABI
  (with an extern bridge so modules can call the db column
  primitives), or define a host command that runs a SAB module with
  a db-provided capability set. Until then, qmod payloads remain
  SA-text modules executed by the plugin's evaluator.
- REG-VM-2 (sci interpreter): the SAB interpreter's registered
  `&scalar`-argument segfault must be cleaned up before any
  in-process SAB execution is considered for the db plugin; the db
  plugin's trust boundary is more sensitive than a worker process
  (design page, risk register).
- REG-VM-3 (sci interpreter): when SAB payloads land, the
  interpreter needs a fuel/step budget hook equivalent to §3
  (per-instruction charge with a hard, configurable limit surfaced
  as an error) so the metering discipline survives the move.
- REG-VM-4 (step 2, this repo): write-procedure modules (through
  the existing single-table transaction API only) and the AOT
  registration tier are step 2; they were not started here.

## 7. Verification record

- Base point: sa_plugin_db master
  `53f6ae134555464fc9ebca8a8337b0ea353ac739` (the remote HEAD when
  this line opened; the base worktree was a pristine checkout of it).
- `zig build test --summary all` (with
  `-Dsa-repo-root=/content/sa_all/sci
  -Dsa-std-lib=/content/sa_all/sci/zig-out/lib/libsa_std.a`) on the
  pristine base tree: **RC=0**, failure name set empty, 206 unit
  tests passing.
- The same command on this change: **RC=0**, 129/129 steps
  succeeded, **212/212 unit tests passed** (206 baseline + 6 new:
  three qmod VM tests in `src/db_stub.zig`, three CLI
  diagnostic/classification tests in `src/plugin.zig`), failure
  name set empty. Compared by failure name set, there are zero
  regressions and no removed tests.
- The 129 steps include the extended `install-smoke` (the VM
  section of `tests/smoke_installed.sh` in §5), the CLI skill
  surface check (14 items, with the updated
  `db exec <hash> [--params <file>] [--fuel <steps>]` entry), the
  docs guard, and the protected-benchmark-artifact guard.
- Manual CLI spot checks against a dev-installed build confirmed
  the rendered diagnostics end to end: `--fuel 10` and
  `SA_DB_QMOD_FUEL=10` both print
  `error[SA-DB-CLI]: DB query fuel exhausted` with the
  raise-the-limit hint and exit code 1; `--fuel 0` prints
  `error[SA-DB-CLI]: invalid DB fuel limit`; a normal exec prints
  `result_u64: 550`, `fuel_used: 54`, `fuel_limit: 1000000` for the
  loop module (the primitive form of the same query reports
  `fuel_used: 7`).
