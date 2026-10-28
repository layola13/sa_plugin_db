# VM Concurrency — Epoch-Pinned Snapshot Readers + Single-Writer Epoch Commit

Status: implemented (concurrency line on top of VM step 1,
`docs/vm_query_layer.md`). Concurrency model decided by JEV
(jev-1.14.0, `db-concurrency-model`): **Model A — snapshot readers +
single-writer epoch commit**, p=0.99. User hard constraints, verbatim
in effect: the db stays embedded and niche-but-safe — **no network
listener, no wire protocol, no service mode, no SQL parser** is added
by this work; concurrency exists only as in-process multithreaded
qmod execution. The security trio — capability grants
(`db_read`/`db_write`/`db_atomic_cursor`, per table and column),
register-time static checking (`DbCapabilityEscalation`), and fuel
metering — must hold unchanged under concurrency, and is revalidated
under concurrency in §7.

## 1. What already existed at the step-1 base (measured, not assumed)

- **Storage is already epoch-versioned.** A table manifest
  (`<table>.manifest`) names the active versioned meta
  (`<table>.meta.<epoch>`); segment/index/dict/blob artifacts are
  immutable per epoch, and artifacts become durable only when a
  later meta/manifest publish points at them. Commit point = the
  manifest publish (`writeMeta` → `publishWrittenMeta`).
- **The qmod read path already materializes a private snapshot.**
  `loadReadTable` resolves the active meta through the manifest,
  then copies every segment file's bytes into memory, validating
  each file's length, SHA-256, and block hashes
  (`validateQmodFileBytes`) on every exec. After the load, a reader
  touches no shared state.
- **The qmod write path already serializes writers.**
  `evalWriteDbQmod` / `evalReadWriteDbQmod` / `evalAtomicDbQmod`
  hold the table write lock (`acquireTableWriteLock`: flock on
  `<table>.write.lock` for disk roots, the process write-lock
  registry for memory roots) across load → stage → commit.
  `commitWriteTable` revalidates the full meta
  (`tableMetaStillCurrent`, else `StaleMetadata`), rewrites only
  dirty segments at `epoch + 1`, rebuilds indexes, and publishes.
- **The native layer already had the read-snapshot discipline.**
  `openReadSnapshot` pins the active epoch and reads immutable
  artifacts lock-free in durable mode (see the `snapshotTable`
  comment in `src/table.zig`). The qmod layer had no equivalent
  named protocol — that asymmetry is what this line closes.

## 2. Gaps this line closes

- **G1 — no in-process epoch identity.** A qmod exec's epoch choice
  was an unnamed side effect of whichever manifest read happened
  during its load. A read-write exec loads its read table and its
  write table at unrelated instants, so its read side was not tied
  to any single committed epoch; and with no pin registry, nothing
  in-process could state which epochs are in use (the precondition
  for any reclamation discipline).
- **G2 — parallel exec was an unproven accident.** `execQuery` had
  no thread-safety contract, no concurrent test, and no parallel
  surface; whether N threads could execute qmods against one table
  was unknown (see the before/after evidence in §8).
- **G3 — no epoch GC discipline.** Nothing stated when a superseded
  epoch stops being in use in-process.
- **G4 — commit visibility was implicit.** A commit became visible
  to in-process readers only because each exec re-read the manifest;
  there was no protocol step that publishes a new epoch to the
  in-process runtime.

## 3. Design: the epoch runtime (`src/epoch_runtime.zig`)

A small in-process registry, one entry per table name:

```
TableEpochState {
    mutex:            std.Thread.Mutex   // guards the fields below
    current:          *EpochPin          // latest committed epoch known in-process
    live_pins:        usize              // diagnostics / test observability
}
EpochPin {
    epoch:            u64
    meta_source:      []const u8         // owned bytes of <table>.meta.<epoch>
    refs:             std.atomic.Value(u32)
    retired:          bool               // superseded; freed when refs drain
}
```

Registry-internal allocations use `std.heap.page_allocator` (the
same precedent as `wal_dir_synced` in `src/table.zig`), so pin
lifetimes never couple to a per-exec allocator.

### 3.1 Pin protocol (readers)

`pinLatest(allocator, table) -> *EpochPin`:

1. Read the table manifest (the cross-process source of truth).
2. Under the table-state mutex, compare the manifest epoch with
   `current`:
   - equal → reuse `current`;
   - manifest newer (an external or in-process commit landed) →
     adopt: build a pin for the manifest epoch (reading the
     versioned meta it names), swap `current`, retire the old pin;
   - manifest older (a restore published an older epoch) → adopt
     the regression the same way. The manifest always wins; the
     runtime never invents an epoch.
3. Increment the pin's refcount and return it. Loads then consume
   the pin's `meta_source` — one named, consistent epoch per exec.

`release(pin)`: decrement; when a retired pin's refcount reaches
zero it is freed (the in-memory GC point, §3.3) and the table's
live-pin count drops.

Load integration (surgical, in `src/db_stub.zig`): `loadReadTable`
splits into a pinning front-end and `loadReadTableFromMeta`, which
takes the meta source as a parameter. The read-only evaluator pins
for the duration of its segment load; the cross-table read-write
evaluator pins its read table at the same point. The pin covers
the load window: segment bytes are copied into exec-private memory
after per-file hash validation, exactly as before — the pin adds
the epoch identity and the drain accounting, it does not change
what is verified.

### 3.2 Commit protocol (writer)

Unchanged staging discipline — step 1's, inherited by step 2's
write procedures and its AOT tier, which both commit through
`commitWriteTable`: stage into owned buffers under the table write
lock, revalidate meta freshness, write dirty segments at
`epoch + 1`, rebuild indexes, publish the manifest. The manifest
publish remains the durable, cross-process commit point.

This line adds the in-process publication step at the success tail
of `commitWriteTable`: `epoch_runtime.noteCommitted(table,
next_epoch)` swaps the registry's `current` to a fresh pin for the
new epoch and retires the previous one. Readers that pin after the
swap start on the new epoch; readers already pinned finish on
theirs. When no write happens (no dirty segments), there is no
epoch bump and no swap — unchanged from before.

### 3.3 Epoch GC discipline

- **In memory:** a retired `EpochPin` is freed exactly when its
  refcount drains to zero — never while a reader holds it. No other
  code frees pins.
- **On disk:** superseded epoch artifacts are *retained by design*
  in this storage engine — `recoverTable` scans versioned metas as
  recovery candidates and validates their segment files, and
  snapshots copy epoch artifacts — so automatic on-disk reaping
  would break recovery. This line therefore adds no file deletion.
  The contract any future on-disk reaper must obey is stated here
  as binding: reap only under the table write lock, only epochs
  strictly older than the oldest live pin for that table, and never
  the manifest-current epoch. The pin registry is the authority for
  "oldest live pin".

### 3.4 Atomic cursor ruling

The atomic-cursor evaluator is **writer-class**, and this line
rules its semantics explicitly: an atomic exec takes the table
write lock, stages from the **latest committed epoch** (it does not
read from a reader pin), applies its `atomic_rmw_add` operations to
the staged epoch, and publishes `epoch + 1` like any other writer.
"Atomic" names the read-modify-write semantics of the instruction
within the staged epoch; it is not a lock-free CAS against live
segment bytes. Concurrent atomic execs therefore serialize in
commit order with no lost updates (proven in §7: N threads × M
increments leave exactly N×M).

### 3.5 What is deliberately not here

- No change to `src/table.zig` or `src/plugin.zig`: the storage
  primitives (manifest publish, write lock, versioned metas) were
  sufficient, and the CLI surface is untouched (the CLI skill list
  and its guard tests are step-2-adjacent surface; the parallel
  surface below is an API for in-process hosts).
- Registration is unchanged and not made concurrent: registering is
  an operator action, and exec of a hash whose registration is
  in flight behaves exactly as before.
- WAL interplay is unchanged: qmod epochs are the durable manifest
  epochs; folding committed-but-uncheckpointed WAL data remains
  the native layer's discipline (`openReadSnapshot` / verify /
  snapshot), exactly as at step 1.

## 4. Parallel execution surface

- **Thread-safety contract for `execQuery` / `execQueryWithFuel`:**
  safe to call concurrently from multiple threads against the same
  or different tables, provided each call passes a thread-safe
  allocator (the per-thread `DebugAllocator` pattern the native
  layer's concurrency tests already use). All evaluator state —
  including the `FuelMeter` — is per-call; `src/db_stub.zig` holds
  no mutable globals; the shared state below it (table-layer
  caches, WAL registries) was already mutex/atomic-guarded.
- **`execQueriesParallel`**: a batch helper that runs a slice of
  independent exec requests on a bounded worker pool (one thread
  per request up to the requested parallelism), each with its own
  allocator and fuel meter, returning per-request results/errors
  in request order. It is a scheduling convenience over the same
  `execQueryWithFuel`; it adds no new execution semantics.

## 5. Semantics reconciliation (existing commands under the epoch protocol)

| Operation | Disposition under Model A |
| --- | --- |
| `snapshot` | **Keep, unchanged.** Already pins the active epoch and copies immutable artifacts lock-free in durable mode; qmod pins do not interact with snapshot copies. |
| `restore` | **Keep, unchanged.** Runs under the table write lock and republishes an older epoch as current. In-process readers keep their pinned (newer) epoch and finish consistently — its files persist; the next pin adopts the restored epoch (§3.1 regression rule). |
| `compact` | **Keep, unchanged.** Write-locked; merges segments and publishes `epoch + 1` without deleting superseded segment files. Pinned readers are unaffected; the runtime adopts the new epoch on the next pin or `noteCommitted`. |
| `lock` / `unlock` | **Keep, unchanged.** The meta `locked` flag still refuses write loads (`Locked`) and still permits reads; `lock` also makes artifacts read-only on disk. Concurrency does not widen or narrow it. |
| `verify` / `recover` | **Keep, unchanged.** Operate on the manifest-current epoch (plus WAL folding / versioned-meta scan) exactly as before; the pin registry is not consulted, and §3.3's retention rule exists precisely to protect `recover`. |
| `register` / `inspect` | **Keep, unchanged.** Operator actions outside the concurrency model. |

## 6. Step-2 alignment

Step 2's write-set staging is the same `loadWriteTable` →
`commitWriteTable` machinery (§1), so the commit hook of §3.2 sits
at the one point both the interpreted evaluators and the AOT tier
commit through. If step 2 reshapes `commitWriteTable`'s tail, the
integration cost is moving one `noteCommitted` call. Step 2's
registry-record changes (class derivation, exec-time revalidation)
are orthogonal: pins key on table names and epochs, never on
registry records.

*Status note (after step 2 landed as sa_plugin_db `be8468d5`):*
step 2's design doc confirms its AOT write procedures commit
through the same `commitWriteTable`, so the single
`noteCommitted` hook covers interpreted and AOT writers alike,
as designed. This line's staging is based on the step-1 commit,
so integration rebases it onto the step-2 tip; the expected
overlap is `src/db_stub.zig` (the `loadReadTable` /
`commitWriteTable` / exec area) plus the one-function storage
fix in `src/table.zig` described in §7.1. `src/plugin.zig` is
untouched.

## 7. Verification

All runs on the Colab box (hostname `2d60bdf6bf1a`), full fixture
tree, `zig build test --summary all` against sci
`28fd2ceb` / sa_plugin_sla `754edb2f`.

**Name-set regression.** Baseline at the step-1 commit
(`320158f`): 212/212 unit tests pass, failure name set ∅
(126/129 build steps; the single failed step,
`check-benchmark-artifacts`, was environmental — the subset
staging lacks `benchmark_test/` and a git repo; the harness was
reconstructed box-side only, staging untouched, and the guard
then passes standalone). After this line: **221/221 tests,
129/129 steps, failure name set ∅** — the 212 baseline tests plus
9 new ones (3 epoch-runtime unit tests, 5 concurrency/safety
tests, 1 regression test from §7.1). The pre-fix gate was re-run
three extra times with fresh seeds: 220/220 each time (that
stage predates the regression test), no flaky names.

**Stress oracle** (`qmod concurrent readers and single writer
keep the epoch oracle`). 200-row table; one writer commits
set-all v = 1..10 while 4 readers × 30 execs sum the column.
Every observed sum equals v×200 for some committed v (never a
torn value), each reader's v is non-decreasing, the final sum is
2000 (the serial oracle), `verifyTable` is clean, and the pin
registry drains to zero live pins with
`currentEpoch == base + 10`. The bench's mixed runs (§8) repeat
the same oracle over 3.4k–4.9k reads per round with 0
violations.

**Atomic cursor** (`qmod concurrent atomic cursor increments are
exact`). 4 threads × 12 increments return the old values 0..47,
each exactly once; the final counter is 48. The writer-class
ruling of §3.4 holds under concurrency: no lost or duplicated
increments.

**Safety trio under concurrency.**
- *Grants*: while 3 reader threads hammer valid execs,
  registration of a store under `db_read`, a load through an
  undeclared pointer, and an `atomic_rmw` under `db_read` are
  each rejected with `DbCapabilityEscalation`
  (`qmod grant rejections hold under concurrent read load`),
  on top of the pre-existing rejection family in the 212.
- *Fuel*: a runaway read loop and a fuel-starved writer (limit
  10) both terminate `FuelExhausted` on their own meters while
  concurrent readers keep returning the correct sum; the starved
  writer leaves zero partial writes
  (`qmod fuel exhaustion under concurrency stays per-exec`).
- *No listener surface*: this line adds no networking at all.
  Census of `src/*.zig` after the change: zero occurrences of
  `socket` or `listen` anywhere in the plugin sources (the epoch
  runtime included). The db remains in-process and file-backed
  only.

**Parallel contrast** (`qmod parallel exec surface is ordered
and scales readers`). The same batch of 8 CPU-bound loop-sum
execs over 20,000 rows takes 3209 ms on 1 worker and 1034 ms on
4 workers (3.10×) through `execQueriesParallel`; a mixed
[read, write, read] batch returns ordered outcomes, each read
observing a whole epoch. §8 has the full thread sweep.

### 7.1 Defect found by the bench: chained epoch suffixes (fixed)

The first bench run exposed a pre-existing step-1 defect in the
storage layer, unrelated to the epoch design but fatal to any
sustained write workload: `rewriteColumnFileForEpoch`
(`src/table.zig`) formed each new segment file name by appending
`.e<epoch>` to the *previous* epoch's path, so names chained
without bound (`wbench.col1.0.dat.e2.e3.…e56`). After 55
successful commits the next commit failed with
`SnapshotCorrupted` and the table stayed permanently unwritable
(the manifest froze at epoch 56), while the codebase's own
cleanup enumeration (`deleteTableArtifacts`) already assumes
the canonical `<base>.e<epoch>` form — the chained files were
not even reachable for deletion. Every other versioned artifact
(meta, indexes, dicts) is named from the table name directly;
this function was the sole deviation.

Fix: the function now strips trailing `.e<digits>` suffixes to
recover the base name before appending the new epoch once.
Recorded paths in existing metas are explicit, so old tables
(including already-chained ones) keep reading and heal on their
next commit. Regression test `qmod many sequential commits keep
canonical epoch file names` (90 sequential commits) provides the
dual evidence required by house rules: with the fix reverted,
the suite is 220/221 and the *only* failure is that test; with
the fix, 221/221. After the fix the bench writes 60/60 commits
in every round (§8) instead of collapsing at 55.

## 8. Benchmarks

**Headline numbers.** On the bench machine below, our db's
maximum effective concurrency is **8 reader threads** — exactly
the core count: read throughput climbs to a peak of **535.6
exec/s** (column-sum executions over 20,000 rows; point reads
peak at **980.4/s**) and then stops growing. Peak write
throughput is **26.1 commits/s** for full-table set-all commits
over 2,000 rows, and **2.5 commits/s** over 20,000 rows while 4
parallel readers sustain **398.5 reads/s** against the same
table with zero oracle violations. Past saturation (16–32
threads) throughput stays flat (~420–450 exec/s, no cliff, no
errors) while latency queue-inflates: p50 grows 12.5 ms → 64.3
ms and p99 blows out 30.6 ms → 167.0 ms. The knee is the core
count, and the post-saturation shape is queueing, not collapse.

**Machine.** Colab box, hostname `2d60bdf6bf1a`: 8 cores, AMD
EPYC 7B12, 50 GB RAM (MemTotal 53,467,180 kB), Linux, box-local
disk. The box is shared with other work lines, so every scenario
ran 3 rounds and the tables below are medians of the rounds;
single-round outliers are visible in the raw CSVs produced by
`scripts/bench/run_bench.sh` / `bench_pg.sh`.

**Method.** Fixed dataset for all three systems: a 20,000-row
table `t(id u64/int, val u64/int)` with `val = 1` (sum =
20,000), plus a 2,000-row twin for writes. Equivalent
operations: our qmod primitives (`col_sum`, single-row load,
set-all write module) vs SQLite `SELECT sum(val)` / `SELECT val
WHERE id = 12345` / transactional full-table `UPDATE`, vs the
same SQL on PostgreSQL via pgbench. Access paths, stated
plainly: ours is **in-process direct calls** into the plugin's
query layer (ReleaseFast bench binary, `scripts/bench/`); SQLite
is **in-process library calls** through python3's `sqlite3`
module (3.45.1) — its multi-thread rows pass through CPython
threads and are GIL-bound, so its 1-thread rows are the clean
comparison; PostgreSQL 16 is a **local unix-socket** server
(private throwaway cluster created for this bench and deleted
after; pgbench clients, per-transaction logs for percentiles).

### 8.1 Our concurrency curve (medians of 3 rounds)

Read sweep — `col_sum` execs, 480 per tier, whole-epoch oracle
checked on every exec (bad = 0 in every round and tier):

| threads | exec/s | p50 | p99 |
| --- | --- | --- | --- |
| 1 | 142.0 | 7.01 ms | 8.11 ms |
| 2 | 276.2 | 7.21 ms | 8.22 ms |
| 4 | 411.3 | 10.62 ms | 11.26 ms |
| 8 | **535.6** | 12.52 ms | 30.58 ms |
| 16 | 420.1 | 37.11 ms | 76.89 ms |
| 32 | 449.2 | 64.30 ms | 167.03 ms |

Point reads — single-row loads by ordinal, 480 per tier:

| threads | exec/s | p50 | p99 |
| --- | --- | --- | --- |
| 1 | 222.7 | 4.48 ms | 4.87 ms |
| 4 | 811.2 | 4.79 ms | 6.61 ms |
| 8 | **980.4** | 8.06 ms | 13.62 ms |

Writes — single writer, 60 set-all commits per round on the
2,000-row table: **26.1 commits/s**, p50 36.18 ms, p99 84.39 ms
(p99 across only 60 samples per round is spiky: 37.5 / 84.4 /
165.2 ms by round).

Mixed — 1 writer + 4 readers on the 20,000-row table, 25
commits per round: readers sustain **398.5 exec/s** while the
writer lands **2.5 commits/s**; 3,371–4,861 oracle-checked
reads per round, **0 violations** (every read saw a whole
committed epoch).

### 8.2 Reference frame (same machine, same data)

SQLite (medians; multi-thread rows are CPython-GIL-bound, see
Method):

| scenario | threads | ops/s | p50 | p99 |
| --- | --- | --- | --- | --- |
| sum | 1 | 1,058.1 | 0.83 ms | 1.42 ms |
| sum | 8 | 4,828.3 | 1.38 ms | 4.97 ms |
| sum | 16 | 5,058.3 | 1.39 ms | 9.37 ms |
| point | 1 | 164,780.7 | 5 µs | 10 µs |
| point | 8 | 12,589.9 | 0.58 ms | 1.59 ms |
| write | 1 | 181.3 | 5.53 ms | 6.11 ms |

PostgreSQL 16 via pgbench (medians; unix socket):

| scenario | clients | ops/s | p50 | p99 |
| --- | --- | --- | --- | --- |
| sum | 1 | 918.0 | 1.07 ms | 1.32 ms |
| sum | 8 | 3,671.1 | 1.95 ms | 5.22 ms |
| sum | 16 | 3,715.0 | 3.90 ms | 9.13 ms |
| point | 1 | 14,655.9 | 59 µs | 116 µs |
| point | 8 | 24,842.8 | 192 µs | 519 µs |
| write | 1 | 175.8 | 5.00 ms | 14.71 ms |

### 8.3 Attribution — where we lose, and why

We lose every absolute-throughput row against both references
on this dataset, and the reasons split cleanly into model
differences and implementation gaps:

- **Per-exec snapshot materialization (implementation gap,
  dominant).** Every one of our execs re-reads the manifest and
  meta, loads the segment files, and revalidates lengths,
  SHA-256 and per-block hashes before the query runs — a
  ~4.5–7 ms floor per exec at 20,000 rows, paid identically by
  a full column sum and by a single-row point read. SQLite and
  PostgreSQL answer from an already-open, warm database, so
  their per-op costs (0.83 ms sum / 5 µs point for SQLite;
  1.07 ms / 59 µs for PG) measure query work only. This is the
  single biggest lever for future work: the epoch pin registry
  shipped by this line is exactly the identity a materialized-
  snapshot cache would key on (pin epoch + meta hash), but
  caching snapshots is deliberately out of this line's scope —
  the step-1 discipline "no state survives an exec" stays
  until someone designs that cache's invalidation story.
- **Write cost (model difference + maturity).** A commit
  rewrites every dirty segment as a new immutable artifact,
  rebuilds the table's indexes, and publishes a new manifest —
  36 ms at 2,000 rows, ~400 ms at 20,000 rows. SQLite/PG update
  in place under a WAL/journal (~5 ms for the same full-table
  update). Immutable epoch artifacts are the price of the
  snapshot-reader model itself; the index-rebuild share of the
  cost is implementation maturity, not model.
- **What does hold up.** Our scaling *shape* is the cleanest of
  the three: throughput rises monotonically to the core count
  with no lock cliff (the references saturate too — PG's sum
  plateaus at ~3,700/s from 8 clients, SQLite's point reads
  *degrade* 13× from 1→8 python threads under the GIL), and our
  post-saturation failure mode is latency inflation with zero
  errors and zero oracle violations, never wrong data. The
  product claim of this db was never raw speed — it is the
  capability/fuel safety posture of §7 plus verified snapshot
  consistency — but the snapshot-reuse gap above is recorded
  here as the honest first optimization target.

## 9. Performance line: pinned snapshots and exec-path caches

Target set by the user (2026-10-28): per-scenario throughput at
≈99% of the same-machine SQLite/PostgreSQL references, higher if
reachable. This section records what changed and the semantic
equivalence argument for each change; §9.4 carries the measured
table.

### 9.1 Design

- **Pinned snapshot cache** (`Snapshot` in `src/db_stub.zig`).
  The first exec to pin a (table, epoch, meta-hash) materializes
  the epoch's read columns through the unchanged legacy load —
  manifest/meta resolution, schema-hash check, per-file length +
  SHA-256 + block-hash validation — and attaches the result to
  the epoch pin itself (`EpochPin.attachment`). Later execs on
  the same pin borrow the immutable columns; the pin hold now
  spans the exec (released by `ReadTable.deinit`), and the
  snapshot is freed by the pin-free hook when the pin retires and
  drains. Snapshots over 256 MiB are not cached; those execs take
  the legacy load with identical results.
- **Manifest-witness fast path.** When the registry's current
  pin matches the manifest's published (epoch, meta_sha256)
  (`readActiveManifestWitness` + `pinCurrentIf`), the exec skips
  re-reading the meta file entirely. Any mismatch takes the full
  resolution path, which is also what adopts newer epochs.
- **Content-addressed exec caches.** Registry meta parses,
  qmod payloads, and parsed programs (lines + labels) are cached
  under the SHA-256 of the exact bytes they were built from; the
  bytes are still read and hashed per exec wherever the uncached
  path read them, so a hit proves byte identity. Payload entries
  are keyed by the registry-verified hash and stored only after
  the hash check passes. Meta entries are reference-counted so a
  re-registration can retire an entry without freeing it under
  a reader.
- **Scan folds.** Column primitives fold over typed word slices
  (with a runtime alignment check and an `align(1)` fallback),
  letting the compiler vectorize; per-row conversions are the
  exact expressions of the scalar path, so results are
  bit-for-bit identical. `loadColumnValueKind` reads through
  fixed-size array pointers (the runtime-slice form of `readInt`
  compiled to a byte-wise fallback in this toolchain).
- **`col_fill`.** The write-side counterpart of the read scan
  primitives: row 0 encodes through `storeColumnValue` (identical
  cast/range rules), the remaining rows reuse the encoded pattern.
  Fuel is charged per row, as with read primitives.
- **Commit diet.** Versioned column files no longer fsync their
  parent directory per file (the `writeArtifactFile` rule):
  publish always ends with one directory fsync in the same
  directory, which is what makes the artifact reachable and
  durable; per-file content fdatasync ordering is unchanged.
  The commit freshness check compares the active meta's SHA-256
  against the loaded meta's hash instead of re-parsing and
  deep-comparing every field.

### 9.2 Semantic changes and equivalence

1. **Validation timing (segments, schema).** Validation happens
   at snapshot materialization (once per epoch per process), not
   per exec. Within the storage layer's own operations an
   epoch's artifacts are immutable — commits write new files and
   publish by manifest swap — so re-validating identical
   content-addressed bytes per exec could only re-derive the
   same verdict. Epoch advance/restore is adopted immediately
   (manifest + pin identity are re-checked per exec). The delta
   is confined to out-of-band edits of an already-pinned epoch's
   files mid-flight, which the epoch model places outside its
   consistency domain; a fresh process, or a fresh epoch,
   materializes and validates from disk exactly as before.
2. **Commit freshness.** Byte identity (SHA-256) replaces the
   parsed deep-compare. It is strictly stronger — any field
   change flips the hash. A byte-different but value-equal meta
   (hand-reformatted outside the plugin) now counts as changed
   where the deep compare counted it as current: the
   conservative direction for an optimistic-concurrency guard,
   and unreachable through the plugin's own deterministic
   serializer, where one logical meta has one byte form.
3. **Directory fsync merging.** Removing the per-segment dir
   fsync does not reorder durability: segment content is
   fdatasynced before the rename, the meta and manifest are
   fdatasynced in turn, and the publish's closing dir fsync makes
   every pending entry in the directory durable before the
   commit is reported. A crash before that final sync can lose
   the new entries together — in which case the old manifest,
   hence the old epoch, is what survives, intact.
4. **No safety-posture change.** Grants are still enforced from
   the registry meta on every exec (the cache is keyed by the
   meta file's own content hash, re-read per exec); register-time
   static checks are untouched; fuel is charged per statement
   and per scanned/filled row exactly as before. No network,
   listener, SQL, or wire surface was added (the §7 census
   still holds: zero `socket`/`listen` in `src/`).

### 9.3 What did not change

Benchmark methodology and reference parameters are the
concurrency line's (§8): same harness (`scripts/bench/`), same
datasets, same SQLite defaults (journal=delete,
synchronous=FULL), same PG bench. One bench-side change: the
set-all qmods use the new `col_fill` primitive — the scenario is
unchanged ("set every row to a constant", the counterpart of
SQL `UPDATE ... SET val = c`); the interpreted per-row store
loop it replaces remains covered by the unit suite.

### 9.4 Results

Final round: box `2d60bdf6bf1a`, one window, medians of 3
rounds, same harness (`scripts/bench`), reference systems
untuned (SQLite defaults journal=delete/synchronous=FULL; PG
defaults). The window carried neighbour load (sci integration
and slaredis lines); both reference systems show the same
inflation (PG point p50 64 µs vs 75–77 µs in quieter rounds,
PG write 109/s vs 175.8/s in the section-8 era), so ratios are
the meaningful figure. Pre-line baseline is section 8.

| scenario | before | after | SQLite | PG | vs SQLite | vs PG |
|---|---:|---:|---:|---:|---:|---:|
| readsum 1t | 142.0/s | 6048/s | 1236/s | 823/s | 489% | 735% |
| readsum 8t | 535.6/s | 15386/s | 4375/s | 2639/s | 352% | 583% |
| readsum 32t | — | 3380/s | 2912/s | 3413/s | 116% | 99% |
| point 1t | 222.7/s | 12099/s (p50 68 µs) | 167727/s (5 µs) | 13152/s (64 µs) | 7% | 92% |
| point 4t | — | 24863/s | 32945/s | 22334/s | 75% | 111% |
| point 8t | 980.4/s | 21134/s | 10968/s | 22447/s | 193% | 94% |
| write 1t | 26.1/s | 81/s (p50 12.1 ms) | 173/s (5.8 ms) | 109/s (7.9 ms) | 47% | 74% |
| mixed 4t readers | 398.5/s | 12070/s | — | — | — | — |
| mixed 4t writer | 2.5/s | 51.3/s | — | — | — | — |

Suite on the box: 222/222 (the 221 of section 7 plus the
col_fill equivalence test). Concurrency oracle: unchanged,
0 violations.

Per-optimization measured contributions (box profiles):
pinned snapshot + vectorized folds: readsum 1t 142 → ~3000/s
era (profile: ~510 µs of segment hashing + ~500 µs of scalar
conversion removed from the hot path); col_fill: write
evaluation 44.2 ms → ~0.16 ms per call in the profile;
manifest-witness read path + dir-fsync merge + SHA freshness:
point 1t p50 283 → 114 µs era, commit fsyncs 5 → 4;
content-addressed exec caches: point p50 114 → 85 µs;
manifest witness fast scan: point p50 85 → 75 µs;
write-side snapshot COW: removes per-commit segment reads on
the hot table (visible in mixed, where readers keep the pin
warm); signature-spec cache: point p50 75 → 68 µs.

Remaining gaps, with profiling-grade attribution:

- point 1t vs SQLite (7%): not a tuning gap. SQLite's 5 µs is
  an in-process function call on an already-open connection.
  The plugin's exec contract mandates, per operation, fresh
  registry-meta and manifest reads (the freshness semantics of
  section 8), currently ~30 µs of the 68 µs p50 all-in. Against
  the client-server reference (PG, same op shape) the line is
  at 92–111%.
- write (47% / 74%): commit latency is sync-bound. Per commit
  the epoch protocol pays 3 fdatasync + 1 dir fsync (measured
  2.4–6.3 ms each in-window; raw fdatasync-after-write p50
  1.25 ms on this disk), versus ~2 for SQLite and ~1 for PG
  (WAL). CPU per commit is ~1.5–1.9 ms of the 12.1 ms p50.
  Reaching 99% here requires collapsing the commit to a
  single synced append (a WAL-shaped commit path), a storage
  change beyond this line's protocol-preserving scope; the
  table layer's existing WAL path for transactions is the
  natural base for a follow-up line.

## 10. WAL-shaped epoch commit (follow-up line)

Target: the write scenario at ≈99% of the same-machine
SQLite/PG references, by collapsing the qmod epoch commit to a
single synced WAL append — without weakening any durability,
recovery, or safety guarantee of the epoch protocol.

### 10.1 Investigation: what the four syncs protect, and why the table WAL never served this path

The qmod commit (`commitWriteTable` in `src/db_stub.zig`, used
by write procedures, the AOT tier, and the atomic-cursor
evaluator) publishes a new epoch in four synced steps (durable
mode, one dirty segment file, no user indexes — the bench
shape; each additional dirty segment file adds one fdatasync,
each rebuilt index file adds one more):

1. **Segment fdatasync** — `rewriteColumnFileForEpoch` writes
   each dirty segment's new versioned file (`.e<epoch+1>`) via
   temp file + fdatasync + rename, no directory sync. Protects:
   the segment *content* is on stable storage before anything
   names it.
2. **Meta fdatasync** — `writeVersionedMeta` writes the new
   epoch's versioned meta JSON the same way. Protects: the
   meta (file names + SHA-256 + block hashes for every segment)
   is durable before the manifest points at it.
3. **Manifest fdatasync** — `publishWrittenMeta` writes the
   manifest the same way. Protects: the commit point itself —
   the atomic epoch switch — is durable.
4. **Directory fsync** — `publishWrittenMeta` ends with one
   parent-directory fsync. Protects: all three renames'
   directory entries become durable together; a crash before
   it can lose the new entries as a set, in which case the old
   manifest (hence the old epoch) survives intact (§9.2.3).

CPU per commit is ~1.5–1.9 ms of the 12.1 ms p50 (§9.4); the
rest is these four syncs at 2.4–6.3 ms each in-window.

The table layer's WAL (`<table>.wal`, §"WAL — Phase 1" in
`src/table.zig`) already commits row transactions with a
single fdatasync, but it never served the qmod path, for a
structural reason: its records are *row operations*
(ROW/DICT_PUT/BLOB_PUT between TX_BEGIN/TX_COMMIT) replayed
through a `WriteTransaction`, while the qmod layer never
builds a `WriteTransaction`. It stages whole column-segment
byte images in `db_stub.WriteTable` and commits them through
`commitWriteTable` → `commitTableMetaWithRebuiltIndexesUnlocked`.
The two staging models share the manifest epoch chain but not
a commit vehicle; §3.5 recorded the split ("WAL interplay is
unchanged … folding … remains the native layer's discipline").
Small row transactions additionally keep the legacy path by
policy (the 4096-byte rule in `commitWriteTransaction`), which
this line mirrors for epoch commits.

### 10.2 Design: epoch units in the same WAL

The fix reuses the existing WAL file, framing
(`u32 payload_len | payload | u64 crc64-xz(payload)`), append
helper (`walAppendSync`: append + exactly one fdatasync;
directory fsync only at file creation, tracked per process),
checkpoint thresholds (100 txs / 4 MiB / 30 s), and the
fold-before-read discipline of the native layer
(`openReadSnapshot` / `verifyTable` / `recoverTable` /
begin-overlay). It adds one record family — the *epoch unit*,
a self-contained description of one qmod epoch commit:

- `EPOCH_BEGIN` (tag 6): tag | txid u64 | base_epoch u64.
- `EPOCH_FILE` (tag 7): tag | path_len u32 | path | bytes —
  one per dirty segment file; `path` is the versioned relative
  path the legacy commit would have written, `bytes` its full
  staged content.
- `EPOCH_META` (tag 8): tag | the new epoch's full meta JSON,
  serialized exactly as `writeVersionedMeta` would serialize
  it (segment file metas already point at the new paths and
  hashes; index rebuild is deferred to the fold, where the
  legacy publish performs it).
- `EPOCH_COMMIT` (tag 9): tag | txid u64 | new_epoch u64.

Commit (`commitWriteTable`, WAL branch — taken when durable
mode is on, the table is not a memory root, every dirty
segment fits the record cap, and the total staged dirty bytes
are ≥ 4096, mirroring the row WAL's threshold policy; smaller
commits keep the legacy publish bit-for-bit):

1. Freshness check, unchanged.
2. Per dirty segment, compute the versioned path and FileMeta
   from the staged bytes in memory (`fileMetaForEpochBytes`,
   the hash half of `rewriteColumnFileForEpoch`) — no writes.
3. Frame BEGIN + FILE×n + META + COMMIT and append with one
   `walAppendSync` — **one fdatasync is the whole commit**.
4. `epoch_runtime.noteCommitted`, as the legacy tail does.

Publication is deferred to a *fold*, performed by the unified
checkpointer (`checkpointWalLocked`), which now collects an
ordered unit stream (row transactions and epoch units share
one epoch chain: each unit's base must equal the running
epoch; stale units are skipped; a gap is `VerifyFailed` —
loud, never silently dropped). Row units fold through the
existing replay + legacy commit; an epoch unit folds by
(a) verifying every FILE payload against the unit meta's
FileMeta (length + SHA-256 + block hashes — the same checks
as a segment load), (b) writing the files with the legacy
write discipline (content fdatasync before publish, no
per-file directory sync), and (c) publishing via
`commitTableMetaWithRebuiltIndexesUnlocked`, which rebuilds
indexes from the materialized segments and performs the
legacy meta + manifest publish. The WAL is truncated (and the
truncation fdatasync'd) only after every unit is published —
the existing rule, unchanged.

When folds happen (boundedness — the WAL never holds more
than the thresholds allow, and the tip state below is bounded
by the same thresholds):

- **Readers** (`loadReadTable`): fold before resolving
  whenever epoch units are pending — this process's own
  (tip cache ahead of the manifest) or another's (a restarted
  or read-only process has no tip entry, so pending epoch
  units are detected from the WAL itself via
  `walHasPendingEpochUnits`, cached per WAL length) —
  read-after-commit visibility is the standing contract, so
  the first reader after a WAL commit publishes it. A table
  whose WAL was folded by another process is detected by
  epoch equality and not re-folded. Row-only WALs are not
  folded on this path; that remains the native layer's
  discipline (§3.5), exactly as before.
- **Writers** (`loadWriteTable`, under the table write lock):
  below the checkpoint thresholds they stage from the *tip*
  (below) instead of folding; at the thresholds, or when the
  pending stream contains row units (which the columnar
  staging model cannot overlay), they fold first, under the
  lock, via the locked checkpoint variant.
- **Native layer**: unchanged call sites fold the unified
  stream — `beginWriteTransaction` checkpoints instead of
  overlay-replaying when the valid prefix contains epoch
  records (the row overlay cannot absorb a wholesale segment
  replacement); `openReadSnapshot`, `verifyTable`,
  `recoverTable`, and the direct dict/blob reads fold exactly
  as before, now including epoch units.

The writer's tip is a storage-layer cache (`EpochTip` in
`src/table.zig`): the tip meta JSON plus the newest payload
per carried file path, keyed by (root, table) and validated
per staging against the manifest witness (epoch + meta
SHA-256 of the chain base) and the WAL length — both cheap
reads the write path already performs in spirit. Validation
failure (another process appended, folded, or restored)
drops the cache entry and rebuilds the tip by parsing the
WAL (bounded by the thresholds), or folds if the stream is
not epoch-only. Staging from the tip borrows payload bytes
under the write column segments' existing copy-on-write
discipline; the tip's epoch and meta hash are also the
commit-time freshness witness while a tip is live
(`tableMetaStillCurrent`), so load and commit always compare
against the same "active meta" definition. Cross-process
readers observe epoch units at `loadReadTable` (above);
row-WAL commits keep the §3.5 discipline (snapshot / verify /
recover folds), unchanged.

### 10.3 Semantics and equivalence

- **Committed = durable.** The commit is acked only after
  the epoch unit's single fdatasync returns. Everything
  needed to reconstruct the epoch (segment images + meta) is
  inside the synced unit; a crash after the ack replays it at
  the next fold. A crash *during* the append leaves a torn
  tail: the unit is incomplete and is dropped whole — the
  previous epoch remains the committed state, exactly as a
  crash before the legacy manifest publish behaved.
- **No half epochs.** Readers only ever resolve through the
  manifest (published epochs) or a fully folded tip; a
  partially applied fold is impossible because the fold
  publishes with the legacy protocol (segment content synced
  before the manifest names it) under the table write lock.
  The concurrency oracle's invariant — every read sees one
  whole committed epoch — is preserved by construction and
  re-run (§10.4).
- **Torn tail vs mid-file corruption.** A crash can only
  tear the *tail* of the WAL: the framed prefix parser stops
  at the first incomplete/CRC-invalid record and the fold
  treats the remainder as a torn tail **only if no valid
  frame exists after the stop point**. If a resync scan finds
  a valid frame beyond it, the damage is mid-file corruption
  and the fold fails loudly with `VerifyFailed`
  (`SnapshotCorrupted` at the qmod layer) instead of silently
  dropping committed units. This guard applies whenever the
  stream involves epoch records; row-only streams keep the
  Phase-1 parser behavior bit-for-bit.
- **Freshness, grants, fuel, static checks.** Unchanged:
  staging still validates the schema hash and segment hashes
  (tip payloads are validated against the tip meta's hashes
  at staging, exactly as file loads validate), the commit
  still re-checks meta freshness (against the tip while one
  is live, the manifest otherwise — byte-identity in both
  cases), and no exec-semantics surface changes: no network,
  listener, SQL, or wire surface is added (the §7 census
  still holds).
- **Restores and removal.** `removeTable` already deletes
  the WAL with the table's artifacts; the tip cache entry is
  dropped at the same point, and at every fold. A restore
  that republishes an older epoch while units are pending
  breaks the units' base chain, and the next fold fails
  loudly — the same exposure the row WAL has today, not a
  new silent path.

### 10.4 Results

Verified before the bench window was lost (Colab runtime
`b5e506eb1e40`, 8 cores; suite logs' SHA-256 recorded by the
main session: baseline `ad69f6ffc99217…`, this branch
`58e767222f50…`):

- Suite: baseline tree (perf tip `6bc54f0`) 222/222; this
  branch 232/232. Name-set diff: zero missing, exactly the
  ten new tests of §10 added (five table-level WAL tests, five
  qmod tests including the three crash-recovery classes of
  §10.3: kill -9 survival, torn tail, mid-file corruption).
  The same 232/232 also passed on the local VM in a clean run;
  the one timing-sensitive test (`qmod parallel exec surface
  is ordered and scales readers`) flakes under local 2-core
  load on the pristine baseline as well.
- Bench ratios (write 1t / mixed vs SQLite and PG, readsum /
  point spot checks): **pending re-verification**. The only
  bench attempt on the new runtime died at the harness build
  step (`zig` missing from the detached shell's PATH) and the
  runtime was retired before a corrected run could finish.
  No §10 performance number is claimed until the same-window
  rerun listed in §11.8 lands.

## 11. Group commit and mixed-load tuning (WAL phase 2)

Phase 1 (§10) collapsed the per-commit cost to one synced WAL
append, but the commit still runs *synchronously inside the
table write lock*: a writer holds the lock across staging,
evaluation, and the fdatasync wait, so concurrent writers
serialize on the sync latency itself (≈2–6 ms per commit on
the bench disk), and every commit advances the epoch (snapshot
churn under mixed load). Phase 2 pipelines the commit: staging
and evaluation leave the lock, epoch units queue in memory,
and a leader appends a whole batch of units with **one**
fdatasync. It changes no on-disk format and no durability
semantic; it is a scheduling change inside the qmod write
path (the write-only and read-write evaluators,
`evalWriteDbQmod` and `evalReadWriteDbQmod` — the native row
path and the atomic-cursor path keep the phase-1 shape).

### 11.1 Why not OCC / rebase

A staged epoch unit is bound to its base epoch in three
places at once: the versioned segment file names, the meta
JSON (epoch field, file table), and the WAL framing
(base_epoch / new_epoch). Rebasing a staged unit onto a moved
tip is therefore a re-serialization, and it is only sound if
the writer's *read set* did not intersect the intervening
writes — the qmod evaluator keeps no read-set tracking, and
`loadWriteTable` materializes whole columns, so a conservative
read set is the whole table. Rather than grow read tracking
into the evaluator (a semantics-adjacent change), phase 2
keeps phase 1's strict serial order and moves only the *wait*:

- Writers stage and evaluate concurrently against deep-copied
  (owned) tip snapshots (§11.2), in any order.
- A unit may enter the commit queue only if its base is
  exactly the queue's chain tip (epoch + meta SHA-256, checked
  under the coordinator mutex). The queue therefore extends
  the epoch chain in staging-completion order, one unit per
  epoch, bit-for-bit the serial order phase 1 produced.
- A writer whose base went stale while it evaluated re-runs
  the whole exec against the new tip (bounded:
  `GROUP_STALE_RETRIES = 2`), then falls back to the phase-1
  locked flow, whose `ExecError.StaleMetadata` surface is the
  pre-existing contract. Re-running is safe: a write exec has
  no effect outside its staged table until commit.
- The legacy locked flow and the group flow never mix for one
  table while the queue is non-empty: *every* fallback to the
  locked flow (a commit that is not WAL-eligible — oversized
  segment, sub-threshold with an idle queue — or a writer
  whose stale retries are exhausted) first takes the
  coordinator's **exclusive token**, which is granted only
  when the queue is empty and no leader is active, and which
  makes new submissions decline (and queue up for the token
  in turn) while it is held. Both directions need the guard:
  without it, the locked flow stages from the manifest while
  the staging tip is ahead of it and its freshness check
  fails the exec spuriously; and a group batch submitted
  while a fallback commit is in flight would append behind
  the fallback's solo append, tripping the leader's
  pre-length check and poisoning the batch. Other locked
  commit paths (atomic cursor, AOT) need no token: they stage
  from the manifest under the write lock, and with a queue
  active the staging tip is ahead of any manifest base, so
  their freshness check rejects the commit before anything
  is appended.

### 11.2 Staging without the write lock

Phase 1 staged from the tip cache by *borrowing* its payloads,
sound only because every tip retirement path needed the write
lock the stager held. Group staging borrows nothing shared:
`epochWalStagingOwned` deep-copies the tip (meta JSON + carried
payloads, bounded by the checkpoint thresholds) under the
tip-cache mutex; the copies live in the `WriteTable` and die
with it. Non-carried segments are read from their versioned
files as before — such files are immutable once written, and a
concurrent fold can only unlink them (an open read is
unaffected; a not-yet-open read fails and the exec re-stages).
The fold-first cases of phase 1 (mixed WAL stream, checkpoint
due at staging) first fold under the write lock — held for
the fold only, never across staging or a sync wait — and
then stage again; only a stream that is still not stageable
afterwards (or a checkpoint already due) declines to the
drained locked flow. While the queue is
non-empty the staging tip is the in-memory chain state:
`epochWalStaging` validates it against the coordinator's
projected WAL length (file length + queued bytes) instead of
the manifest witness, which folds may legitimately move under
it (§11.4).

### 11.3 The commit queue, the leader, and the ack contract

Per (root, table) coordinator state (process-local, like the
tip cache): a FIFO of pending units, the chain tip, the
durable frontier (`visible_wal_len`, `visible_epoch`), a
leader flag, and a poison flag (§11.5). A pending unit holds
its framed bytes (serialized at staging time), the
`EpochCommitFile` views and meta JSON (borrowed from the
waiting writer's staged table, which outlives the wait), and a
completion cell. Submission merges the unit into the staging
tip (the phase-1 tip note-append, with projected lengths) and
extends the chain tip atomically with the base check.

The first submitter to find no active leader becomes the
leader; leadership is a role of a writer thread, never a
dedicated thread (no new lifecycle in the plugin). The leader
loop:

1. Collect the batch: up to `GROUP_COMMIT_MAX_BATCH = 32`
   queued units, and at most `GROUP_COMMIT_MAX_BATCH_BYTES =
   8 MiB` of framed bytes. One optional linger
   (`GROUP_COMMIT_LINGER_US`, default **0**): if the batch is
   a singleton *and* another writer is mid-staging, the leader
   may wait that long for it. Default zero because under any
   real contention the sync latency (ms) dwarfs the staging
   gap, so batches form naturally during the previous sync;
   a nonzero default would tax the uncontended writer — the
   write-1t case — for batch-mates that do not exist.
2. Take the table write lock (inter-process) for the append
   section only. This keeps phase 1's cross-path invariant —
   every WAL append in the process (row path included) is
   serialized — with the hold shrunk from stage+eval+sync to
   append+sync. Verify the WAL length equals the batch's
   expected pre-length; a mismatch means a foreign process
   appended, and the batch fails into the poison path.
3. Append the concatenated unit bytes with **one**
   `walAppendSync` — one fdatasync for the whole batch.
4. Advance the durable frontier (still holding the write
   lock, so no fold can observe synced-but-unfrontiered
   bytes), release the lock, do the per-unit bookkeeping
   (checkpoint counters, tip note-append bookkeeping,
   `epoch_runtime.noteCommitted` once with the batch's final
   epoch), and only then complete the cells: **ack strictly
   after sync** — a caller is told "committed" only when its
   batch's fdatasync has returned success.

Visibility is the same order, stated as an invariant:
**no pin can observe epoch E before the sync that made E
durable has completed.** In-process readers resolve through
the manifest or through a fold; the fold (§11.4) is clamped
to the durable frontier, and the staging tip — the only
structure that knows about queued units — is never a pin
source. A cross-process reader has no coordinator; if it
folds complete units whose writer has not finished syncing,
the fold itself performs the full durable publish (segment
syncs, meta sync, manifest sync, directory sync) before any
pin can resolve the epoch, so the epoch still becomes
visible only after *a* complete durable publish of it. The
test suite pins this down in-process: with a batch's sync
held open by the sync gate (§11.7), new pins keep resolving
the old epoch, and the new epoch appears only after the gate
opens and the batch acks.

Pipelining (staging of batch *n+1* during the sync of batch
*n*) needs no extra machinery and no extra durability
argument: staging touches only private copies and immutable
files, queued units are invisible and inert until appended,
and a failed batch invalidates queued successors through the
poison path rather than through any state a stager could
have observed as committed.

### 11.4 Folds, frontier clamp, and snapshot retention

- `checkpointWalLocked` clamps its parse to the durable
  frontier whenever the coordinator holds state for the
  table: units past the frontier are not folded, full stop.
- While the queue is non-empty (or a batch is in flight) the
  fold additionally performs **no WAL truncate and no tip
  drop**; it re-anchors the tip entry to the post-fold
  manifest witness. Folded units left in the file become
  stale (base < disk epoch) and are skipped by later folds —
  the pre-existing stale rule. When the queue is idle, the
  fold is the phase-1 fold verbatim (truncate + tip drop).
- Reader-side fold skip: the coordinator publishes the
  durable frontier epoch alongside the frontier length, and
  a read whose witness already reaches the frontier skips
  its fold entirely while the queue is active — readers
  never queue behind the leader's (possibly slow) sync just
  to confirm a state they can already see. A witness behind
  the frontier still folds, clamped as above, and publishes
  only durable units.
- Epoch churn: one batch advances the epoch chain by its
  unit count but publishes **one** newly pinnable tip per
  sync, and `noteCommitted` retires the registry's current
  pin once per batch, not once per writer.
- Retention bounds (unchanged mechanisms, stated for the
  record): in-process snapshots are bounded by the snapshot
  cache size cap in `snapshotForPin` (over-cap snapshots fall
  back to per-file loads); pending WAL state is bounded by
  the checkpoint thresholds (100 units / 4 MiB / 30 s), which
  the staging path enforces as in phase 1; the oldest live
  pin (`epoch_runtime.oldestLiveEpoch`) remains the floor
  any reaper must respect. Reclaiming orphaned on-disk
  segment files of superseded epochs is *not* changed by
  phase 2 and remains governed by fold cadence, as in
  phase 1 — listed as not-covered, not silently implied.

### 11.5 Failure semantics

- Batch append or sync error: every unit in the batch fails
  with that error; every unit queued behind it fails too
  (its chain base never landed). No acks are granted. The
  coordinator is poisoned and the tip entry dropped; the
  next operation on the table folds first (under the write
  lock), which adopts complete units and discards a torn
  tail by the phase-1 rules — the standard outcome-unknown
  resolution for a commit whose sync reported an error.
- WAL length mismatch at the leader's check: the byte
  offset is bookkeeping, not the invariant — the invariant
  is that the durable tip equals the batch head's base. A
  local fold can legitimately move the offset (it publishes
  the very units the batch chains onto, then truncates), so
  the leader re-proves the tip from disk
  (`durableEpochTip`, the fold parser's read-only twin) and
  resyncs the offset when the durable tip is exactly the
  head's base and the file ends at the last complete frame.
  Anything else — a foreign append, a torn tail, a different
  tip — takes the poison path above; single-process
  deployments, the plugin's design center as with the tip
  cache, never produce a foreign append.
- A writer thread that dies waiting (host-level fault) is
  out of scope, exactly as a phase-1 writer dying mid-commit
  was: its unit is either in a batch (completed by the
  leader) or not yet queued (never existed).

### 11.6 Parameters

| Parameter | Default | Rationale |
|---|---|---|
| `GROUP_COMMIT_MAX_BATCH` | 32 units | Bounds one sync's blast radius and ack latency spread; at the §9 staging cost a 32-batch is ~50 ms of staging feeding ~one 2–6 ms sync — the sync stops being the bottleneck long before 32. |
| `GROUP_COMMIT_MAX_BATCH_BYTES` | 8 MiB | Twice the 4 MiB checkpoint threshold: a batch can carry one full WAL's worth of units without the queue's memory footprint exceeding two checkpoints' worth. |
| `GROUP_COMMIT_LINGER_US` | 0 | See §11.3: nonzero only helps bursty arrivals at the direct expense of the uncontended writer. Compile-time constant; revisit with bench data, not by default. |
| `GROUP_STALE_RETRIES` | 2 | Each retry costs one re-evaluation; two retries absorb the common two-writer collision; beyond that the locked flow guarantees progress. |
| Checkpoint thresholds | 100 units / 4 MiB / 30 s | Unchanged from the row WAL; they bound queue + tip memory and fold work per pin. |

### 11.7 Tests

Deterministic sync control uses a test seam in the WAL sync
wrapper (`testSyncGate` in table.zig): when a test installs
it, `walAppendSync` signals entry and waits for release
before writing. It is never installed outside tests, and the
recovery/fold logic has no test-only branches — the gate
only stretches a real sync in time. New tests (six, in
db_stub.zig): a batch of concurrent writers acked only
after the sync lands, with chained epochs and a single
final state; the visibility test of §11.3 (gate held: new
pins see the old epoch; gate open: acks land, new pins see
the new epoch); pipelining (a second writer finishes
staging and queueing while the first batch's sync is
gated); readers summing repeatedly while a sync is gated
(never starved, always the old value); four ungated writers
on one table all landing through the queue (base collisions
absorbed by re-staging); kill -9 over a process whose three
writer threads commit through the queue (acked commits all
fold back on reopen, one whole final state, epoch +3).

### 11.8 Pending re-verification (box recovery)

All performance claims of phases 1–2 are unverified until
the box returns: same-window `scripts/bench` rerun for
write 1t, write multi-thread, and mixed (this branch vs
062e0e2-era references, SQLite and PG untuned), readsum /
point spot checks against §9.4 magnitudes, and the full
suite on the 8-core box including the timing-sensitive
parallel test. The local correctness evidence for phase 2
is the suite subset runnable on the 2-core VM (§11.7 tests
plus the WAL/qmod filters), reported with the change.

