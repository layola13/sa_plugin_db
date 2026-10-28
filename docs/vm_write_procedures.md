# VM Write Procedures + AOT Escape Hatch — Step 2

Status: implemented (step 2 of the VM support plan recorded in sala
`content/10_db/07_vm_support.html`; this closes REG-VM-4 from
`docs/vm_query_layer.md` §6). Scope delivered: write stored
procedures as an explicitly declared registry class, fuel metering
and atomicity guarantees for the write path with acceptance proof,
and the AOT escape hatch (per-module opt-in native tier). REG-VM-1
to REG-VM-3 remain open host/sci work and are not touched here —
see §6 for the precise landed/spec split.

## 1. Recon conclusions (what existed before this change)

- The qmod evaluator already had write shapes (write-only,
  read-write, atomic cursor) staging through the single-table
  transaction discipline the design page mandates: `loadWriteTable`
  reads every segment into owned in-memory buffers, `store` /
  `atomic_rmw_add` mutate only those buffers, and
  `commitWriteTable` — invoked exactly once, at `return` — checks
  the table meta is still current (`StaleMetadata` otherwise),
  rewrites only dirty segments at the next epoch, rebuilds indexes,
  and commits the meta. Any error or fuel exhaustion before `return`
  drops the staged write set with the evaluator frame. Step 2 keeps
  this machinery and adds the missing product surface around it;
  no second write path was built.
- Step 1's FuelMeter is created per exec and shared by all five
  evaluator shapes, so the write path was already metered; what was
  missing was acceptance proof that metering + staging together
  guarantee zero partial writes (now §4).
- Registration recorded only grants. Nothing in the registry record
  said *what kind* of module a hash names, and exec trusted the
  record's grant entries without re-checking them against the
  payload — the record is plain JSON on disk, so a tampered record
  was only caught where it happened to break a hash check.
- No AOT surface existed anywhere in the plugin.

## 2. Write procedures as a declared class

The module class is **derived from the grant entries** and written
into the registry record (meta version 2):

- Any `db_write:<table>` or `db_atomic_cursor:<table>` grant makes
  the module a **procedure** (`kind: "procedure"`,
  `write_capability: true`, `write_tables: [<table>...]`,
  deduplicated in grant order). All other modules stay
  `kind: "query"` with `write_capability: false`.
- Derivation — not self-declaration — is the source of truth, so a
  module cannot claim to be read-only while holding a write grant,
  and `sa db register` / `sa db inspect` print the derived class.
- Version 1 records stay readable: readers derive the class from
  `grant_entries` for them, and re-registering the same module
  upgrades its record to version 2 in place (verified idempotent).

**Exec-time revalidation.** After the payload hash check, exec now
re-derives everything from the payload itself before any evaluator
runs (`validateExecPayload`):

1. The record's `grant_entries` must equal the grants declared in
   the payload's own `grants [...]` lines, else
   `QueryRegistryCorrupted`.
2. The payload's instructions must not exceed those grants
   (`verifyDbGrants` — the same check registration runs), else
   `DbCapabilityEscalation`.
3. For version 2 records, the stored class fields must agree with
   the class derived from the payload grants, else
   `QueryRegistryCorrupted`.

So a read-only-class module that somehow reaches exec with a store
is refused explicitly, a write procedure whose record was demoted
or escalated on disk is refused explicitly, and nothing is silently
re-classed in either direction.

## 3. Fuel + atomicity on the write path

- The per-exec FuelMeter (step 1: `--fuel` → `SA_DB_QMOD_FUEL` →
  default 1,000,000) covers the write, read-write, and atomic
  evaluators unchanged: 1 step per executed instruction, hard
  `FuelExhausted` error, never a shape-mismatch fallthrough — a
  runaway write procedure cannot be re-executed by a second shape.
- Atomicity is the staging discipline of §1: stores land in the
  in-memory write set only; `commitWriteTable` runs only at
  `return`. Fuel exhaustion or any mid-procedure error therefore
  leaves **zero partial writes**, and a successful return commits
  every store at once (with the meta-freshness check as the
  optimistic-concurrency guard). No procedure can touch segment
  files, schema, or another table's data: pointers resolve only
  against the granted tables' staged columns.

## 4. Acceptance evidence for §2–§3 (unit tests, `src/db_stub.zig`)

- Class recorded: a `db_write` module registers as
  `procedure`/`write_capability: true` with `write_tables` in the
  stored v2 record and in `inspect` output; a `db_read` module
  registers as `query`; re-register is idempotent.
- Tamper cases, all rejected at exec with `QueryRegistryCorrupted`:
  record grants escalated (`db_read` → `db_write`) after register;
  record grants demoted (`db_write` → `db_read`) after register;
  stored `kind` forged (`procedure` → `query`).
- Fuel/atomicity: a read-write procedure scaling 3 rows ×10 with a
  5-step budget fails with `FuelExhausted` and both independent
  aggregates still describe the original rows (sum 6,
  sum-of-squares 14) with `verifyTable` clean; the same procedure
  under the default budget commits atomically (sum 60).
- Mid-procedure error: a write procedure whose second store is out
  of range fails with `InvalidFormat`; the first (staged) store is
  rolled back (sum still 6).
- Atomic cursor: an unbounded `atomic_rmw_add` loop cut by fuel
  leaves the cell at its original value (41).
- Step 1's four acceptance items (two-way aggregation 550,
  fuel termination + host survival, hash addressing/tamper,
  read-only register rejection) all still pass — they are part of
  the suite and the smoke below.

## 5. AOT escape hatch

A module opts in **per module, explicitly**: 
`sa db register-aot <hash> --lib <lib.so> [--symbol <name>] [--replace]`
binds a native library — compiled from an SA source through the
toolchain's normal AOT path (`sa build-lib <src> --contract <sai>
--kind shared`) — to the module's hash. The registry record stores
`lib_path`, `lib_sha256`, `symbol`, and `abi_version`. Nothing is
compiled by the plugin and nothing switches silently:

- Without an AOT record the module always runs interpreted; with
  one it always runs native. A different library for the same hash
  is refused (`AotAlreadyRegistered`) unless `--replace` is passed;
  re-registering the identical library is idempotent.
- At registration the artifact is opened and handshaken: it must
  export `sa_db_aot_abi_version` returning the supported ABI
  version (1) and the entry symbol (default `sa_db_qmod_main`),
  else `AotSymbolMissing` / `AotAbiMismatch`; a missing or
  unloadable file is `AotLibraryInvalid`.
- At every exec the library bytes are re-hashed and compared with
  the record, and the handshake repeats. Any drift is an explicit
  error — there is **no fallback to the interpreter** from an AOT
  record.
- Shapes with no AOT tier are refused at registration
  (`AotUnsupportedShape`): atomic-cursor modules (the cursor
  discipline does not map onto the buffer descriptor) and
  blob-grant modules (no evaluator implements blob allocation), as
  are modules naming more than one read or write table and
  signatures exceeding the 32-slot descriptor.

**ABI v1 (descriptor call).** `sa_db_qmod_main(slots, slot_count)`
receives u64 slots in module-signature order: a column parameter
takes two slots (buffer address, buffer byte length), `len` takes
one slot (row count), and each scalar parameter takes one slot
(its value, consumed from the params file exactly as the
interpreters consume it, trailing bytes rejected). Read columns
are passed as the snapshot's merged buffers. Write columns are
staged into one contiguous buffer per column; on a clean return
the staged bytes are copied back (only changed segments marked
dirty) and committed through the same `commitWriteTable` as the
interpreted evaluators — so an AOT write procedure is atomic
under the same transaction discipline and lands byte-identical
results. Relative library paths resolve against the working
directory at open time; absolute paths are recommended in the
record (and required for `sa build-lib -o`, whose own post-link
check opens the artifact by path).

**Trust + metering, stated plainly.** Native code is trusted code:
it runs in-process with raw pointers to the staged buffers, it can
crash the host, and it is **not** instruction-metered — the fuel
budget governs the interpreted tier. That trade is exactly why
the tier is an explicit per-module opt-in rather than a default,
mirroring the design page ("hot modules keep an AOT escape
hatch"). Exec output marks native runs with `engine: aot` and
reports `fuel_used: 0`.

**End-to-end proof** (`tests/smoke_installed.sh`, step-2 section,
against a dev-installed plugin; sources in `docs/vm_examples/`):
the step-1 loop query compiled with `sa build-lib`
(`sum_amount_where_qty.aot.sa` / `sum_amount_where_qty_aot.sai`)
registers and returns 550 with `engine: aot`, matching the
interpreted result on the same table; the bonus write procedure
(`add_bonus.proc.sa`) runs interpreted (2 rows, AMOUNT total
840 → 1040), a `--fuel 5` cut leaves the total at 1040, and after
restoring the pre-procedure snapshot its native build
(`add_bonus.aot.sa` / `add_bonus_aot.sai`) lands the identical end
state (2 rows, total 1040). Negative cases in the same section: a
text file as library → `AotLibraryInvalid` and the target module
keeps running interpreted; substitution without `--replace` →
`AotAlreadyRegistered`. The native sources were also called from
a C host during development: `abi=1`, sum 550, bonus result 2 with
amounts 100/350/40/400/150.

Toolchain notes found while building the examples (recorded for
the next author): the build-lib contract file stem must be a
valid C identifier (no dots — name contracts `*_aot.sai`), and
`sa build-lib -o` should be an absolute path because the
post-link surface check opens the artifact by the given path.

## 6. Landed vs spec-only (REG-VM-1..4)

- REG-VM-4 (this step): **landed** — write procedures (§2–§4) and
  the AOT registration tier (§5) in this repo.
- REG-VM-1 (host/sci): still open, unchanged. No plugin-facing SAB
  execution service exists; qmod payloads remain SA-text modules
  executed by the plugin's evaluator, and AOT payloads are native
  libraries built by the toolchain — neither needs the host SAB
  interpreter inside the db trust boundary.
- REG-VM-2 (sci interpreter `&scalar` segfault): still open,
  unchanged; it remains a precondition for any future in-process
  SAB execution, which this step does not introduce.
- REG-VM-3 (sci interpreter fuel hook): still open, unchanged;
  the metering discipline lives in the plugin evaluator (§3) and
  would need the registered hook only if SAB payloads land.

## 7. Verification record

- Base point: sa_plugin_db master `85060d2` (box HEAD verified
  before opening this line; the local master's step-1 commit
  `320158f` is file-identical to it per the step-1 sha256 audit).
- `zig build test --summary all` (with
  `-Dsa-repo-root=/content/sa_all/sci
  -Dsa-std-lib=/content/sa_all/sci/zig-out/lib/libsa_std.a`) on a
  pristine `85060d2` worktree: **129/129 steps succeeded, 212/212
  unit tests passed**, failure name set empty.
- The same command on this change: **129/129 steps succeeded,
  224/224 unit tests passed** (212 baseline + 12 new: 4 procedure
  class / exec-revalidation, 3 write fuel + atomicity, 3 AOT
  registration validation, 2 AOT diagnostic rendering), failure
  name set empty — zero regressions by failure name set, no
  removed tests. The run includes the extended
  `install-smoke` (`tests/smoke_installed.sh` step-2 section in
  §5: "installed db plugin smoke passed") and the CLI skill
  surface check (15 items, with the new
  `db register-aot <hash> --lib <lib.so> [--symbol <name>]
  [--replace]` entry).
- One intermediate run failed exactly one test by name —
  `db plugin wrapper exports runtime descriptor` expected the
  pre-change skill item count (14) — and was fixed by updating
  the pinned count/positions to the new 15-item surface in the
  same commit that adds the command.
- AOT examples were additionally exercised outside the plugin
  during development: both libraries export
  `sa_db_aot_abi_version` / `sa_db_qmod_main`, and a C host
  calling them through the descriptor ABI observed `abi=1`,
  sum = 550, and bonus result 2 with amounts
  100/350/40/400/150.
- Commits (local master, on top of step 1 `320158f`): `4979a76`
  (2a: procedure class + exec-time revalidation), `51b9074`
  (2b: write-path fuel/atomicity acceptance tests), `b8d9eee`
  (2c: AOT escape hatch), plus the step-2d commit carrying the
  smoke section, the `docs/vm_examples/` procedure/AOT examples,
  the README row, and this document.
